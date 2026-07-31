import Foundation

/// Deterministic synthetic audio for the LID latency sweep.
///
/// LID *latency* depends on how much audio is handed to the model, never on
/// what the audio says — so the sweep needs no microphone, no fixtures and no
/// Norwegian speaker. What synthetic audio cannot measure is LID *accuracy*:
/// none of these signals is speech, so the language the model reports for them
/// carries no information at all.
enum SyntheticAudio {
    enum Signal: String, CaseIterable, Sendable {
        case silence, noise, tone
    }

    /// Peak amplitude of the non-silent signals. Well above the daemon's
    /// silence gate (RMS 0.003) so the sweep exercises the same path a real
    /// utterance would.
    static let amplitude: Float = 0.25
    static let toneHz: Double = 440

    /// `seconds` of `signal` as 16 kHz mono float PCM — the exact shape
    /// `AudioCapture` hands to the transcriber.
    static func make(
        _ signal: Signal,
        seconds: Double,
        sampleRate: Double = AudioCapture.targetSampleRate
    ) -> [Float] {
        let count = max(0, Int((seconds * sampleRate).rounded()))
        switch signal {
        case .silence:
            return [Float](repeating: 0, count: count)
        case .noise:
            // A seeded LCG rather than `Float.random` so two runs of the bench
            // feed the model bit-identical audio and only the clock differs.
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            return (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float(state >> 40) / Float(1 << 24)  // [0, 1)
                return (unit * 2 - 1) * amplitude
            }
        case .tone:
            let radiansPerSample = 2 * Double.pi * toneHz / sampleRate
            return (0..<count).map { Float(sin(Double($0) * radiansPerSample)) * amplitude }
        }
    }
}

/// docs/bilingual.md "Budgets": LID ≤ 30 ms on ANE for a ≤ 10 s utterance.
enum LIDBudget {
    static let millis: Double = 30
    /// The budget is stated for utterances up to this length. Longer cells are
    /// still measured — they are what shows whether length matters at all —
    /// but they are not judged against a budget that does not cover them.
    static let maxUtteranceSeconds: Double = 10
}

/// One (signal, length) cell of the sweep: repeated `detectLangauge` calls on
/// the same buffer, timed on the monotonic clock.
struct LIDCell: Sendable {
    let signal: String
    let seconds: Double
    let sampleCount: Int
    /// Milliseconds per call, in order. Excludes the run's cold call.
    let millis: [Double]
    /// What the model reported for this synthetic buffer. Recorded only to
    /// show that latency is unrelated to it — it is not a language result.
    let detectedLanguage: String?

    var median: Double { Statistics.median(millis) }
    var fastest: Double? { millis.min() }
    var slowest: Double? { millis.max() }

    /// nil when the cell is outside the budget's stated scope (> 10 s) or has
    /// no samples — unmeasured and out-of-scope are both "no verdict", never a
    /// pass.
    var meetsBudget: Bool? {
        guard !millis.isEmpty, seconds <= LIDBudget.maxUtteranceSeconds else { return nil }
        return median <= LIDBudget.millis
    }

    /// Median over the budget, e.g. 2.4 for 72 ms against 30 ms.
    var budgetRatio: Double? {
        millis.isEmpty ? nil : median / LIDBudget.millis
    }
}

struct LIDScalingPoint: Sendable, Equatable {
    let seconds: Double
    let millis: Double
}

/// Does LID latency track utterance length, or is it a fixed cost?
///
/// A least-squares fit of `millis = fixed + perSecond × seconds` over the
/// per-cell medians. The interesting number is `fixedFraction`: how much of
/// the latency at the longest measured length is already there at zero
/// seconds of audio. Near 1.0 means the audio length is nearly irrelevant and
/// what is being paid for is the model's fixed input window.
struct LIDScaling: Sendable {
    /// At or above this fraction the latency is called fixed. 0.8 leaves room
    /// for a real but minor length term without letting a genuinely
    /// proportional cost pass as fixed.
    static let fixedCostThreshold: Double = 0.8

    let points: [LIDScalingPoint]

    /// Distinct lengths measured, sorted. Two are needed for any fit.
    var lengths: [Double] {
        Array(Set(points.map(\.seconds))).sorted()
    }

    /// Median latency across every signal measured at `seconds`.
    func latency(at seconds: Double) -> Double? {
        let matching = points.filter { $0.seconds == seconds }.map(\.millis)
        return matching.isEmpty ? nil : Statistics.median(matching)
    }

    private var fit: (fixed: Double, perSecond: Double)? {
        guard points.count >= 2 else { return nil }
        let xs = points.map(\.seconds)
        let ys = points.map(\.millis)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        // Zero denominator means every point is at the same length: nothing to
        // fit a slope against.
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        return (meanY - slope * meanX, slope)
    }

    /// Latency extrapolated to zero seconds of audio — the part that is not
    /// the audio.
    var fixedMillis: Double? { fit?.fixed }
    /// Extra milliseconds per second of audio.
    var perSecondMillis: Double? { fit?.perSecond }

    /// Share of the latency at the longest measured length that is already
    /// paid at zero seconds. Clamped to [0, 1] — a fit that extrapolates above
    /// the measurement is still just "all of it".
    var fixedFraction: Double? {
        guard let fixed = fixedMillis,
              let longest = lengths.last,
              let atLongest = latency(at: longest),
              atLongest > 0
        else { return nil }
        return min(1, max(0, fixed / atLongest))
    }

    /// nil when the sweep covered fewer than two lengths — one length can
    /// never answer this question.
    var isFixedCost: Bool? {
        guard let fixedFraction else { return nil }
        return fixedFraction >= Self.fixedCostThreshold
    }

    /// Slowest ÷ fastest cell median. Compare against `lengthSpread`: latency
    /// spread far below length spread is the signature of a fixed cost.
    var latencySpread: Double? {
        let values = points.map(\.millis)
        guard let low = values.min(), let high = values.max(), low > 0 else { return nil }
        return high / low
    }

    /// nil for a single-length sweep: "1.00×" would read as a measured result
    /// when nothing was varied.
    var lengthSpread: Double? {
        let lengths = self.lengths
        guard lengths.count > 1, let low = lengths.first, let high = lengths.last, low > 0 else {
            return nil
        }
        return high / low
    }
}

/// Where one LID call's time goes, for a single utterance length.
///
/// `detectLangauge` is pad → mel → encoder → one decode step. Only the pad
/// sees the utterance's real length; everything after it works on the padded
/// window. Splitting them says whether a shorter window is even actionable:
/// it would mean re-converting whichever stages dominate, not changing a
/// constant in RoutingTranscriber.
struct LIDStageBreakdown: Sendable {
    let seconds: Double
    let padMillis: [Double]
    let melMillis: [Double]
    let encodeMillis: [Double]
    /// Full `detectLangauge` calls on the same buffer, so the residual is
    /// measured against the real path rather than assumed.
    let totalMillis: [Double]

    var pad: Double { Statistics.median(padMillis) }
    var mel: Double { Statistics.median(melMillis) }
    var encode: Double { Statistics.median(encodeMillis) }
    var total: Double { Statistics.median(totalMillis) }

    /// What is left of a full call after pad + mel + encoder: the language
    /// decode step plus per-call overhead. Never negative — clamped, because a
    /// negative residual is measurement noise, not a stage that gives time back.
    var residual: Double { max(0, total - (pad + mel + encode)) }

    /// The stage with the largest median, and its share of the total.
    var dominant: (name: String, millis: Double, share: Double)? {
        let stages = [("mel", mel), ("encoder", encode), ("decode+overhead", residual), ("pad", pad)]
        guard total > 0, let top = stages.max(by: { $0.1 < $1.1 }) else { return nil }
        return (top.0, top.1, top.1 / total)
    }
}

/// A complete `parrot bench lid` run.
struct LIDMeasurement: Sendable {
    let modelID: String
    let sampleRate: Double
    /// The audio window the model's mel front-end is compiled for, read off
    /// the loaded pipeline. Every `detectLangauge` call pads or trims its
    /// input to exactly this many samples before the encoder sees it
    /// (`WhisperKit.detectLangauge` → `padOrTrim`), which is the mechanism a
    /// fixed-cost verdict points at.
    let windowSamples: Int?
    /// The first call after load, timed once and excluded from every cell.
    let coldMillis: Double?
    let cells: [LIDCell]
    /// Per-length stage split. Empty unless `--stages` was passed.
    var stages: [LIDStageBreakdown] = []
    /// False when the measuring binary was built without optimization. Only
    /// the CoreML stages are build-independent; everything around them (mel
    /// packing, the token sampler over a 51865-entry vocabulary) is Swift and
    /// several times slower in a debug build, so a debug number cannot be
    /// judged against the budget.
    var optimizedBuild: Bool = true

    var windowSeconds: Double? {
        guard let windowSamples, sampleRate > 0 else { return nil }
        return Double(windowSamples) / sampleRate
    }

    var scaling: LIDScaling {
        LIDScaling(points: cells.map { LIDScalingPoint(seconds: $0.seconds, millis: $0.median) })
    }

    /// Cells the budget actually covers (≤ 10 s), in sweep order.
    var inScopeCells: [LIDCell] { cells.filter { $0.meetsBudget != nil } }

    /// nil when nothing in the sweep fell inside the budget's scope.
    var meetsBudget: Bool? {
        let judged = inScopeCells
        guard !judged.isEmpty else { return nil }
        return judged.allSatisfy { $0.meetsBudget == true }
    }

    /// Median latency across every in-scope cell — the single number to quote
    /// against the 30 ms budget.
    var inScopeMedian: Double? {
        let judged = inScopeCells.map(\.median)
        return judged.isEmpty ? nil : Statistics.median(judged)
    }
}

/// Parsing for the sweep options, kept pure so the error messages are testable
/// without running a model.
enum LIDSweepInput {
    /// Refuse anything longer than this: past the model's own window it is
    /// only measuring `padOrTrim` on a buffer the encoder never sees.
    static let maxSeconds: Double = 120

    enum ParseError: Error, CustomStringConvertible {
        case notANumber(String)
        case outOfRange(Double)
        case empty
        case unknownSignal(String)

        var description: String {
            switch self {
            case let .notANumber(raw):
                return "not a number: '\(raw)' — pass lengths in seconds, e.g. --durations 1,2,5,10,30"
            case let .outOfRange(value):
                return String(
                    format: "duration out of range: %g — must be > 0 and ≤ %g seconds",
                    value, maxSeconds
                )
            case .empty:
                return "no values given"
            case let .unknownSignal(raw):
                return "unknown signal: '\(raw)' — pick from "
                    + SyntheticAudio.Signal.allCases.map(\.rawValue).joined(separator: ", ")
            }
        }
    }

    static func durations(_ raw: String) throws -> [Double] {
        let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !fields.isEmpty else { throw ParseError.empty }
        var out: [Double] = []
        for field in fields {
            guard let value = Double(field) else { throw ParseError.notANumber(field) }
            guard value > 0, value <= maxSeconds else { throw ParseError.outOfRange(value) }
            if !out.contains(value) { out.append(value) }
        }
        return out.sorted()
    }

    static func signals(_ raw: String) throws -> [SyntheticAudio.Signal] {
        let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !fields.isEmpty else { throw ParseError.empty }
        var out: [SyntheticAudio.Signal] = []
        for field in fields {
            if field == "all" {
                for signal in SyntheticAudio.Signal.allCases where !out.contains(signal) {
                    out.append(signal)
                }
                continue
            }
            guard let signal = SyntheticAudio.Signal(rawValue: field) else {
                throw ParseError.unknownSignal(field)
            }
            if !out.contains(signal) { out.append(signal) }
        }
        return out
    }
}

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

/// What the sweep holds resident and which call path it times (gh#25).
///
/// gh#20 measured `lid-only` and got 19.6 ms; the live daemon on the same
/// release build was ~52 ms. The two extra arms exist to say *which* of the
/// differences between those two situations costs the time, by changing one
/// thing at a time:
///
///   lid-only        1 model resident,  `detectLangauge` called directly
///   three-resident  3 models resident, `detectLangauge` called directly
///   daemon          3 models resident, called through `RoutingTranscriber`
///
/// So `three-resident − lid-only` is the price of the other two pipelines
/// being loaded, and `daemon − three-resident` is the price of the daemon's
/// own call path around the same `detectLangauge`.
enum LIDArm: String, CaseIterable, Sendable {
    case lidOnly = "lid-only"
    case threeResident = "three-resident"
    case daemon

    /// True when the arm needs the Norwegian and English pipelines loaded too.
    var needsFullModelSet: Bool { self != .lidOnly }

    var summary: String {
        switch self {
        case .lidOnly:
            return "1 model resident, detectLangauge called directly"
        case .threeResident:
            return "3 models resident, detectLangauge called directly"
        case .daemon:
            return "3 models resident, called through RoutingTranscriber"
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
    /// What was resident and which call path was timed.
    var arm: LIDArm = .lidOnly
    /// Every model held loaded for this arm, in load order. One entry for
    /// `lid-only`, three for the others.
    var residentModelIDs: [String] = []
    /// Idle seconds inserted before each timed call (`--gap`). Zero means the
    /// calls were made back to back, which is not what the daemon does — see
    /// `LIDComparison`.
    var gapSeconds: Double = 0

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

/// Splits the gh#25 gap — bench 19.6 ms vs live daemon ~52 ms — into the
/// pieces this bench can actually attribute, and names what is left over.
///
/// Arithmetic only, over three in-scope medians. Each term changes exactly one
/// thing relative to the arm above it, so a term is the cost of that one
/// change:
///
///   residency  three-resident − lid-only        the other two pipelines being loaded
///   call path  daemon − three-resident          RoutingTranscriber around detectLangauge
///   remainder  observed − daemon                everything this bench does not model
///
/// The remainder is the honest part. Whatever it is, it is not resident models
/// and not the call path, because those were measured.
struct LIDAttribution: Sendable {
    /// What gh#20 measured: LID alone, called directly.
    let baseline: Double
    /// nil when that arm did not run.
    let threeResident: Double?
    let daemon: Double?
    /// Median from a live daemon session, passed in with `--observed`. The
    /// bench cannot measure this itself — it has no microphone.
    let observed: Double?

    /// A term counts as explaining the gap at or above this share of it.
    /// Below a quarter it is real but not the answer.
    static let materialShare: Double = 0.25

    /// How far the daemon-like arm may sit from the live daemon and still be
    /// called a reproduction. ±25% of a ~50 ms number is ~12 ms, which is
    /// inside the spread a single arm shows between its own calls.
    static let reproductionTolerance: Double = 0.25

    /// Cost of holding the Norwegian and English pipelines resident.
    var residencyCost: Double? {
        threeResident.map { $0 - baseline }
    }

    /// Cost of the daemon's call path around the same `detectLangauge`: the
    /// actor hop, the window copy, the softmax over `langProbs`.
    var callPathCost: Double? {
        guard let daemon, let threeResident else { return nil }
        return daemon - threeResident
    }

    /// A term that came out negative is not a saving — loading a second model
    /// cannot make LID faster, and neither can wrapping it in an actor. It is
    /// direct evidence that the run-to-run spread is wider than the effect, so
    /// the term is reported as unmeasurable rather than as a number.
    static func isMeasurable(_ term: Double?) -> Bool {
        guard let term else { return false }
        return term > 0
    }

    /// How much of the live daemon's latency the most daemon-like arm actually
    /// reproduces. 0.33 means the bench is timing something three times faster
    /// than the thing it claims to model; 1.0 means it is timing the same
    /// thing. nil without `--observed`.
    var reproduction: Double? {
        guard let observed, observed > 0, let top = daemon ?? threeResident else { return nil }
        return top / observed
    }

    /// True when the arms land on the live daemon's number. Whatever conditions
    /// the run used are then the daemon's conditions, and there is no gap left
    /// to split between residency and the call path.
    var reproducesDaemon: Bool {
        guard let reproduction else { return false }
        return abs(reproduction - 1) <= Self.reproductionTolerance
    }

    /// The gap being attributed: the live daemon against gh#20's number when
    /// `--observed` was given, otherwise as much of it as the arms reproduce.
    var gap: Double? {
        guard let top = observed ?? daemon else { return nil }
        return top - baseline
    }

    /// What the arms account for. Only measurable terms count: a negative one
    /// contributes nothing rather than cancelling out a real cost beside it.
    var explained: Double? {
        let terms = [residencyCost, callPathCost].filter(Self.isMeasurable).compactMap { $0 }
        return terms.isEmpty ? nil : terms.reduce(0, +)
    }

    /// The part of the gap no arm reached. nil without `--observed`: with only
    /// bench arms the remainder is zero by construction and printing it would
    /// read as a result.
    var unexplained: Double? {
        guard let observed, let daemon else { return nil }
        return observed - daemon
    }

    /// A term's share of the gap. Unmeasurable terms have no share — printing
    /// "-368% call path" would dress noise up as a finding.
    private func share(_ value: Double?) -> Double? {
        guard Self.isMeasurable(value), let value, let gap, gap > 0 else { return nil }
        return value / gap
    }

    var residencyShare: Double? { share(residencyCost) }
    var callPathShare: Double? { share(callPathCost) }
    var unexplainedShare: Double? { share(unexplained) }

    enum Verdict: Sendable, Equatable {
        /// The arms land on the live daemon's number. There is no gap left to
        /// attribute — this run's conditions are the daemon's conditions.
        case reproducesDaemon
        /// Resident models cost a material share of the gap — the ANE
        /// contention hypothesis, and it would bear on the memory item too.
        case residency
        /// The daemon's call path costs a material share.
        case callPath
        /// The arms reproduce little of the gap. Not contention, not the call
        /// path — those were measured.
        case unexplained
        /// Not enough arms, or nothing to attribute.
        case notAttributable
    }

    var verdict: Verdict {
        // Checked before any share arithmetic: once the arms match the daemon,
        // the residual gap is small enough that ordinary run-to-run spread
        // divided by it produces enormous, meaningless shares.
        if reproducesDaemon { return .reproducesDaemon }
        guard let gap, gap > 0 else { return .notAttributable }
        let candidates: [(Verdict, Double)] = [
            (.residency, residencyShare ?? 0),
            (.callPath, callPathShare ?? 0),
            (.unexplained, unexplainedShare ?? 0),
        ]
        guard let top = candidates.max(by: { $0.1 < $1.1 }),
              top.1 >= Self.materialShare
        else {
            // Nothing clears the bar: with an observed number that itself means
            // the gap is spread thin or elsewhere; without one, there is not
            // enough to rank.
            return unexplained == nil ? .notAttributable : .unexplained
        }
        return top.0
    }
}

/// One `parrot bench lid` invocation: one arm, or several run back to back in
/// the same process for comparison.
struct LIDComparison: Sendable {
    let arms: [LIDMeasurement]
    /// Median `◐ lid … · NNms` from a live daemon session, if the caller
    /// supplied one with `--observed`. gh#25 quotes ~52 ms.
    var observedDaemonMillis: Double?

    var isSingleArm: Bool { arms.count < 2 }

    func measurement(_ arm: LIDArm) -> LIDMeasurement? {
        arms.first { $0.arm == arm }
    }

    func median(_ arm: LIDArm) -> Double? {
        measurement(arm)?.inScopeMedian
    }

    /// nil unless the `lid-only` arm ran: every term is a difference from it.
    var attribution: LIDAttribution? {
        guard let baseline = median(.lidOnly) else { return nil }
        return LIDAttribution(
            baseline: baseline,
            threeResident: median(.threeResident),
            daemon: median(.daemon),
            observed: observedDaemonMillis
        )
    }

    /// The arm to judge against the 30 ms budget: the most daemon-like one
    /// that ran. A pass on `lid-only` is what gh#20 already had, and gh#25 is
    /// the finding that it did not carry over.
    var judgedArm: LIDMeasurement? {
        for arm in [LIDArm.daemon, .threeResident, .lidOnly] {
            if let m = measurement(arm) { return m }
        }
        return nil
    }
}

/// Parsing for the sweep options, kept pure so the error messages are testable
/// without running a model.
enum LIDSweepInput {
    /// Refuse anything longer than this: past the model's own window it is
    /// only measuring `padOrTrim` on a buffer the encoder never sees.
    static let maxSeconds: Double = 120

    /// Longest idle the sweep will insert between calls (`--gap`). Past this a
    /// run stops being a benchmark and becomes an afternoon.
    static let maxGapSeconds: Double = 300

    enum ParseError: Error, CustomStringConvertible {
        case notANumber(String)
        case outOfRange(Double)
        case empty
        case unknownSignal(String)
        case unknownArm(String)

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
            case let .unknownArm(raw):
                return "unknown arm: '\(raw)' — pick from "
                    + LIDArm.allCases.map(\.rawValue).joined(separator: ", ") + ", or all"
            }
        }
    }

    /// Arms always run cheapest-residency first and in a fixed order, whatever
    /// order they were asked for: the `lid-only` arm is only honest while the
    /// other two pipelines have not been loaded yet, and a loaded pipeline
    /// cannot be unloaded again inside one process.
    static func arms(_ raw: String) throws -> [LIDArm] {
        let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !fields.isEmpty else { throw ParseError.empty }
        var out: Set<LIDArm> = []
        for field in fields {
            if field == "all" {
                out.formUnion(LIDArm.allCases)
                continue
            }
            guard let arm = LIDArm(rawValue: field) else { throw ParseError.unknownArm(field) }
            out.insert(arm)
        }
        return LIDArm.allCases.filter(out.contains)
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

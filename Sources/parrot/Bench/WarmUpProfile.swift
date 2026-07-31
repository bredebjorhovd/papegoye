import Foundation

/// One model's load span inside a single warm-up, in seconds relative to the
/// start of that warm-up.
struct WarmUpSpan: Sendable, Equatable {
    let modelID: String
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

/// Collects load spans across the (supposedly concurrent) pipelines of one
/// warm-up. Handed to the transcribers by `parrot bench warmup` only — normal
/// runs pass nil and pay nothing.
///
/// A lock-guarded class rather than an actor: the recorded work happens on
/// several tasks at once, and `now()` must be callable synchronously from
/// inside actor-isolated code without introducing an await point that would
/// itself perturb the measurement.
final class WarmUpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = DispatchTime.now()
    private var spans: [WarmUpSpan] = []

    /// Seconds since this recorder was created, on the monotonic clock.
    func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- origin.uptimeNanoseconds) / 1e9
    }

    func record(modelID: String, start: Double, end: Double) {
        lock.lock()
        defer { lock.unlock() }
        spans.append(WarmUpSpan(modelID: modelID, start: start, end: end))
    }

    /// Snapshot of everything recorded so far, ordered by start time.
    func profile(wallClock: Double) -> WarmUpProfile {
        lock.lock()
        defer { lock.unlock() }
        return WarmUpProfile(
            wallClock: wallClock,
            spans: spans.sorted { $0.start < $1.start }
        )
    }
}

/// What one warm-up cost, and whether its loads actually ran concurrently.
struct WarmUpProfile: Sendable {
    let wallClock: Double
    let spans: [WarmUpSpan]

    /// Below this, `parrot bench warmup` flags the warm-up as effectively
    /// serialized. Perfect overlap is 1.0; three equal serial loads give 0.33.
    /// 0.8 leaves room for load-time contention (shared ANE/disk) without
    /// letting an accidental `await` chain pass as concurrent.
    static let overlapThreshold: Double = 0.8

    /// Sum of the individual load times — what a strictly serial warm-up would
    /// have cost.
    var serialTotal: Double { spans.reduce(0) { $0 + $1.duration } }

    /// The slowest single load: the floor a perfectly overlapped warm-up can
    /// reach, however many models are involved.
    var slowest: WarmUpSpan? { spans.max { $0.duration < $1.duration } }

    /// How close the warm-up got to that floor. 1.0 = the wall clock is just
    /// the slowest model; 1/n = fully serialized across n equal loads.
    /// nil when there is nothing to overlap (fewer than two spans).
    var overlapEfficiency: Double? {
        guard spans.count > 1, wallClock > 0, let slowest else { return nil }
        return slowest.duration / wallClock
    }

    /// Wall-clock seconds spent beyond the slowest single load — the cost of
    /// whatever did not overlap.
    var serializedSeconds: Double? {
        guard spans.count > 1, let slowest else { return nil }
        return max(0, wallClock - slowest.duration)
    }

    /// True when the loads measurably overlapped. nil (not false) when there
    /// is only one model, so the caller can stay silent instead of claiming a
    /// concurrency problem that cannot exist.
    var isOverlapping: Bool? {
        guard let overlapEfficiency else { return nil }
        return overlapEfficiency >= Self.overlapThreshold
    }
}

/// One measured configuration: repeated warm-ups of a freshly built pipeline
/// set. The first iteration is reported separately — it is the only one that
/// pays for cold page cache, so folding it into the median would hide exactly
/// the number this ticket is about.
struct WarmStartMeasurement: Sendable {
    let label: String
    /// Model ids that were loaded, in configuration order.
    let modelIDs: [String]
    /// Wall-clock seconds per iteration, in order. First entry is the cold one.
    let iterations: [Double]
    /// Profile of the last iteration — the warm one worth inspecting for overlap.
    let profile: WarmUpProfile?

    var cold: Double? { iterations.first }

    /// Median of every iteration after the first. nil when only a cold
    /// iteration was run — there is no warm number to report.
    var warm: Double? {
        let rest = Array(iterations.dropFirst())
        return rest.isEmpty ? nil : Statistics.median(rest)
    }
}

/// Three-model warm start against the single-model baseline, versus the
/// spec §7 budget.
struct WarmStartComparison: Sendable {
    /// docs/bilingual.md "Budgets": three-model warm start ≤ 1.5× single-model.
    static let budget: Double = 1.5

    let baseline: WarmStartMeasurement
    let bilingual: WarmStartMeasurement

    /// Warm-start ratio, bilingual ÷ single-model. nil when either side has no
    /// warm iteration, or the baseline is degenerate — better no number than a
    /// meaningless one.
    var ratio: Double? {
        guard let base = baseline.warm, let bi = bilingual.warm, base > 0 else { return nil }
        return bi / base
    }

    /// nil when `ratio` is nil: unmeasured is not the same as passing.
    var meetsBudget: Bool? {
        guard let ratio else { return nil }
        return ratio <= Self.budget
    }
}

enum Statistics {
    /// Median of `values`; even counts average the middle pair. 0 for empty
    /// input — callers guard against that before it can be reported.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}

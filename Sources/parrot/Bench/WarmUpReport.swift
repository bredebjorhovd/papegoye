import Foundation

/// Rendering for `parrot bench warmup`. Pure functions over measurements so
/// the reported verdict — including the "not overlapping" flag — is testable
/// without models or hardware.
enum WarmUpReport {
    static func text(baseline: WarmStartMeasurement?, bilingual: WarmStartMeasurement?) -> String {
        var out: [String] = []
        for m in [baseline, bilingual].compactMap({ $0 }) {
            out.append("\(m.label) · \(m.modelIDs.joined(separator: " + "))")
            out.append(contentsOf: timings(m))
            if let profile = m.profile, profile.spans.count > 1 {
                out.append(contentsOf: overlap(profile))
            }
            out.append("")
        }

        if let baseline, let bilingual {
            let comparison = WarmStartComparison(baseline: baseline, bilingual: bilingual)
            if let ratio = comparison.ratio, let meets = comparison.meetsBudget {
                out.append(String(
                    format: "ratio         %.2f× warm start (budget ≤ %.2f×) — %@",
                    ratio, WarmStartComparison.budget, meets ? "PASS" : "FAIL"
                ))
            } else {
                out.append("ratio         not computable — need a warm iteration on both sides "
                    + "(re-run with --iterations 2 or more)")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func timings(_ m: WarmStartMeasurement) -> [String] {
        var lines: [String] = []
        if let cold = m.cold {
            lines.append(String(format: "  cold        %.3fs", cold))
        }
        if let warm = m.warm {
            let rest = m.iterations.dropFirst()
                .map { String(format: "%.3f", $0) }
                .joined(separator: " / ")
            lines.append(String(format: "  warm        %.3fs  (median of %d: %@)",
                                warm, m.iterations.count - 1, rest))
        } else {
            lines.append("  warm        —  (only a cold iteration was run)")
        }
        return lines
    }

    private static func overlap(_ p: WarmUpProfile) -> [String] {
        var lines: [String] = []
        let slowestLabel = p.slowest.map { String(format: "%@ %.3fs", $0.modelID, $0.duration) } ?? "—"
        lines.append(String(format: "  overlap     wall %.3fs · summed %.3fs · slowest %@",
                            p.wallClock, p.serialTotal, slowestLabel))
        if let efficiency = p.overlapEfficiency, let overlapping = p.isOverlapping {
            if overlapping {
                lines.append(String(format: "              efficiency %.2f ✓ loads overlap", efficiency))
            } else {
                // The thing this ticket asks to flag: three warm-ups that were
                // written to run concurrently but did not.
                let serialized = p.serializedSeconds ?? 0
                lines.append(String(
                    format: "              efficiency %.2f ✗ NOT overlapping — %.3fs of the warm start "
                        + "is serialized (expected ≈ the slowest load alone)",
                    efficiency, serialized
                ))
            }
        }
        for span in p.spans {
            let id = span.modelID.padding(toLength: 22, withPad: " ", startingAt: 0)
            lines.append(String(format: "    %@ %6.3f → %6.3f  (%.3fs)",
                                id, span.start, span.end, span.duration))
        }
        return lines
    }

    static func json(baseline: WarmStartMeasurement?, bilingual: WarmStartMeasurement?) -> String {
        var root: [String: Any] = ["budget": WarmStartComparison.budget]
        if let baseline { root["baseline"] = encode(baseline) }
        if let bilingual { root["bilingual"] = encode(bilingual) }
        if let baseline, let bilingual {
            let comparison = WarmStartComparison(baseline: baseline, bilingual: bilingual)
            root["ratio"] = orNull(comparison.ratio)
            root["meetsBudget"] = orNull(comparison.meetsBudget)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON has no "unmeasured" — an absent number becomes null rather than a
    /// zero a reader could mistake for a result.
    private static func orNull(_ value: Double?) -> Any { value ?? NSNull() as Any }

    private static func orNull(_ value: Bool?) -> Any { value ?? NSNull() as Any }

    private static func encode(_ m: WarmStartMeasurement) -> [String: Any] {
        var dict: [String: Any] = [
            "label": m.label,
            "models": m.modelIDs,
            "iterations": m.iterations,
            "cold": orNull(m.cold),
            "warm": orNull(m.warm),
        ]
        if let p = m.profile {
            dict["overlap"] = [
                "wallClock": p.wallClock,
                "serialTotal": p.serialTotal,
                "efficiency": orNull(p.overlapEfficiency),
                "overlapping": orNull(p.isOverlapping),
                "serializedSeconds": orNull(p.serializedSeconds),
                "spans": p.spans.map {
                    ["model": $0.modelID, "start": $0.start, "end": $0.end, "duration": $0.duration]
                },
            ]
        }
        return dict
    }
}

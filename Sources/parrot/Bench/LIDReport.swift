import Foundation

/// Rendering for `parrot bench lid`. Pure functions over a measurement so the
/// verdict — fixed cost vs tracks-length, and pass/fail against the 30 ms
/// budget — is testable without a model or hardware.
enum LIDReport {
    static func text(_ m: LIDMeasurement) -> String {
        var out: [String] = []
        out.append("lid latency · \(m.modelID) · \(Int(m.sampleRate)) Hz")
        if let windowSamples = m.windowSamples, let windowSeconds = m.windowSeconds {
            out.append(String(
                format: "  mel window  %d samples (%.1fs) — every detectLangauge call pads or trims to this",
                windowSamples, windowSeconds
            ))
        } else {
            out.append("  mel window  unknown — the pipeline did not report an input window")
        }
        if let cold = m.coldMillis {
            out.append(String(format: "  cold        %.1fms  (first call after load; excluded below)", cold))
        }
        out.append("  build       \(m.optimizedBuild ? "release (optimized)" : "DEBUG (unoptimized)")")
        if !m.optimizedBuild {
            out.append("              ⚠ a debug binary spends several times longer in the Swift half")
            out.append("                of the call (mel packing, token sampler). These numbers cannot")
            out.append("                be judged against the budget — re-run `swift build -c release`.")
        }
        out.append("")
        out.append(contentsOf: table(m))
        out.append("")
        out.append(contentsOf: scaling(m))
        if !m.stages.isEmpty {
            out.append("")
            out.append(contentsOf: stages(m))
        }
        out.append("")
        out.append(contentsOf: verdict(m))
        return out.joined(separator: "\n")
    }

    private static func stages(_ m: LIDMeasurement) -> [String] {
        var lines = ["stage breakdown (median per call, \(m.stages.first?.padMillis.count ?? 0) calls per stage)"]
        lines.append("  length      pad      mel  encoder   decode+overhead      total")
        for s in m.stages {
            lines.append(String(
                format: "  %5.1fs  %6.1fms %6.1fms %6.1fms   %6.1fms          %6.1fms",
                s.seconds, s.pad, s.mel, s.encode, s.residual, s.total
            ))
        }
        if let longest = m.stages.max(by: { $0.seconds < $1.seconds }),
           let dominant = longest.dominant {
            lines.append(String(
                format: "  dominant stage at %.1fs: %@ (%.1fms, %.0f%% of the call)",
                longest.seconds, dominant.name, dominant.millis, dominant.share * 100
            ))
        }
        lines.append("  Only `pad` sees the utterance's real length; mel and encoder always run over")
        lines.append("  the padded window, which is why the total does not move with the utterance.")
        return lines
    }

    private static func table(_ m: LIDMeasurement) -> [String] {
        var lines = [String(
            format: "  signal   length     median       min       max   budget ≤ %.0fms (≤ %.0fs utterance)",
            LIDBudget.millis, LIDBudget.maxUtteranceSeconds
        )]
        for cell in m.cells {
            let budget: String
            switch cell.meetsBudget {
            case .some(true):
                budget = String(format: "✓ %.2f× of budget", cell.budgetRatio ?? 0)
            case .some(false):
                budget = String(format: "✗ %.2f× over budget", cell.budgetRatio ?? 0)
            case .none:
                budget = "—  not judged (outside the budget's stated length)"
            }
            let signal = cell.signal.padding(toLength: 8, withPad: " ", startingAt: 0)
            lines.append(String(
                format: "  %@ %5.1fs  %7.1fms  %7.1fms  %7.1fms   %@",
                signal,
                cell.seconds,
                cell.median,
                cell.fastest ?? 0,
                cell.slowest ?? 0,
                budget
            ))
        }
        return lines
    }

    private static func scaling(_ m: LIDMeasurement) -> [String] {
        let s = m.scaling
        var lines = ["scaling (per-cell medians, signals pooled)"]
        guard let fixed = s.fixedMillis,
              let perSecond = s.perSecondMillis,
              let fraction = s.fixedFraction,
              let isFixed = s.isFixedCost,
              let longest = s.lengths.last
        else {
            lines.append("  not computable — the sweep needs at least two different lengths "
                + "(re-run with e.g. --durations 1,10)")
            return lines
        }
        lines.append(String(format: "  fixed cost        %7.1fms   (latency extrapolated to 0s of audio)", fixed))
        lines.append(String(format: "  per second        %7.2fms   (extra cost per second of audio)", perSecond))
        if let latencySpread = s.latencySpread, let lengthSpread = s.lengthSpread {
            lines.append(String(
                format: "  spread             %6.2f× in latency over %.2f× in utterance length",
                latencySpread, lengthSpread
            ))
        }
        lines.append(String(
            format: "  fixed cost is %.2f of the %.1fs latency (fixed above %.2f)",
            fraction, longest, LIDScaling.fixedCostThreshold
        ))
        if isFixed {
            lines.append("  → FIXED COST: LID latency does not track utterance length.")
            if let windowSeconds = m.windowSeconds {
                lines.append(String(
                    format: "    What is being paid for is the model's %.1fs input window, not the audio:",
                    windowSeconds
                ))
                lines.append("    detectLangauge pads or trims every buffer to that window before the")
                lines.append("    encoder runs, so a shorter LID window in RoutingTranscriber cannot help —")
                lines.append("    WhisperKit pads it straight back up.")
            }
        } else {
            lines.append("  → TRACKS LENGTH: latency grows with the amount of audio; a shorter LID")
            lines.append("    window would buy time proportional to how much audio it drops.")
        }
        return lines
    }

    private static func verdict(_ m: LIDMeasurement) -> [String] {
        var lines = ["verdict"]
        guard let meets = m.meetsBudget, let median = m.inScopeMedian else {
            lines.append(String(
                format: "  budget ≤ %.0fms: not judged — no cell fell inside the budget's stated "
                    + "length (≤ %.0fs)",
                LIDBudget.millis, LIDBudget.maxUtteranceSeconds
            ))
            return lines
        }
        let judged = m.inScopeCells
        let over = judged.filter { $0.meetsBudget == false }.count
        if meets {
            lines.append(String(
                format: "  budget ≤ %.0fms: PASS — %d/%d in-scope cells within budget (median %.1fms)",
                LIDBudget.millis, judged.count, judged.count, median
            ))
        } else {
            lines.append(String(
                format: "  budget ≤ %.0fms: FAIL — %d/%d in-scope cells over budget "
                    + "(median %.1fms, %.2f× the budget)",
                LIDBudget.millis, over, judged.count, median, median / LIDBudget.millis
            ))
        }
        if !m.optimizedBuild {
            lines.append("  ⚠ measured from a DEBUG build — not a verdict on the shipped binary.")
        }
        lines.append("")
        lines.append("  Latency only. Synthetic audio says nothing about LID accuracy, and this")
        lines.append("  bench makes no claim about ANE residency — that needs powermetrics.")
        return lines
    }

    /// JSON has no "unmeasured" — an absent number becomes null rather than a
    /// zero a reader could mistake for a result.
    private static func orNull(_ value: Double?) -> Any { value ?? NSNull() as Any }
    private static func orNull(_ value: Bool?) -> Any { value ?? NSNull() as Any }
    private static func orNull(_ value: Int?) -> Any { value ?? NSNull() as Any }
    private static func orNull(_ value: String?) -> Any { value ?? NSNull() as Any }

    static func json(_ m: LIDMeasurement) -> String {
        let s = m.scaling
        let cells: [[String: Any]] = m.cells.map { cell in
            [
                "signal": cell.signal,
                "seconds": cell.seconds,
                "samples": cell.sampleCount,
                "millis": cell.millis,
                "medianMillis": cell.median,
                "minMillis": orNull(cell.fastest),
                "maxMillis": orNull(cell.slowest),
                "meetsBudget": orNull(cell.meetsBudget),
                "budgetRatio": orNull(cell.budgetRatio),
                "detectedLanguage": orNull(cell.detectedLanguage),
            ]
        }
        let root: [String: Any] = [
            "model": m.modelID,
            "sampleRate": m.sampleRate,
            "windowSamples": orNull(m.windowSamples),
            "windowSeconds": orNull(m.windowSeconds),
            "coldMillis": orNull(m.coldMillis),
            "optimizedBuild": m.optimizedBuild,
            "budgetMillis": LIDBudget.millis,
            "budgetMaxUtteranceSeconds": LIDBudget.maxUtteranceSeconds,
            "meetsBudget": orNull(m.meetsBudget),
            "inScopeMedianMillis": orNull(m.inScopeMedian),
            "cells": cells,
            "stages": m.stages.map { s in
                [
                    "seconds": s.seconds,
                    "padMillis": s.pad,
                    "melMillis": s.mel,
                    "encoderMillis": s.encode,
                    "residualMillis": s.residual,
                    "totalMillis": s.total,
                    "dominantStage": orNull(s.dominant?.name),
                ] as [String: Any]
            },
            "scaling": [
                "fixedMillis": orNull(s.fixedMillis),
                "perSecondMillis": orNull(s.perSecondMillis),
                "fixedFraction": orNull(s.fixedFraction),
                "isFixedCost": orNull(s.isFixedCost),
                "latencySpread": orNull(s.latencySpread),
                "lengthSpread": orNull(s.lengthSpread),
                "fixedCostThreshold": LIDScaling.fixedCostThreshold,
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

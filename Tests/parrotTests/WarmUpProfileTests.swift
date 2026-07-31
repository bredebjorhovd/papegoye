import XCTest
@testable import parrot

/// Tests for the warm-start harness's analysis and reporting — the parts that
/// decide whether the three-model warm start met its budget and whether the
/// three loads really overlapped. Pure arithmetic over recorded spans, so no
/// models, microphone, or ANE needed.
final class WarmUpProfileTests: XCTestCase {
    private func span(_ id: String, _ start: Double, _ end: Double) -> WarmUpSpan {
        WarmUpSpan(modelID: id, start: start, end: end)
    }

    // MARK: - Overlap analysis

    func testFullyConcurrentLoadsAreOverlapping() {
        // Three loads started together; wall clock ≈ the slowest one.
        let profile = WarmUpProfile(
            wallClock: 0.55,
            spans: [
                span("whisper-tiny", 0.00, 0.18),
                span("whisper-small.en", 0.00, 0.43),
                span("nb-whisper-small", 0.00, 0.55),
            ]
        )
        XCTAssertEqual(profile.serialTotal, 1.16, accuracy: 0.001)
        XCTAssertEqual(profile.slowest?.modelID, "nb-whisper-small")
        XCTAssertEqual(profile.overlapEfficiency ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(profile.serializedSeconds ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(profile.isOverlapping, true)
    }

    func testSerializedLoadsAreFlagged() {
        // The regression this harness exists to catch: three warm-ups written
        // to run concurrently that in fact ran back to back.
        let profile = WarmUpProfile(
            wallClock: 1.16,
            spans: [
                span("whisper-tiny", 0.00, 0.18),
                span("whisper-small.en", 0.18, 0.61),
                span("nb-whisper-small", 0.61, 1.16),
            ]
        )
        XCTAssertEqual(profile.overlapEfficiency ?? 0, 0.55 / 1.16, accuracy: 0.001)
        XCTAssertEqual(profile.serializedSeconds ?? -1, 0.61, accuracy: 0.001)
        XCTAssertEqual(profile.isOverlapping, false)
    }

    func testPartialOverlapSitsOnTheThreshold() {
        // Slowest load 0.80s; anything under 1.00s wall clock passes at 0.8.
        let atThreshold = WarmUpProfile(
            wallClock: 1.00,
            spans: [span("a", 0.0, 0.8), span("b", 0.0, 0.5)]
        )
        XCTAssertEqual(atThreshold.overlapEfficiency ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(atThreshold.isOverlapping, true, "exactly at the threshold counts as overlapping")

        let below = WarmUpProfile(
            wallClock: 1.10,
            spans: [span("a", 0.0, 0.8), span("b", 0.0, 0.5)]
        )
        XCTAssertEqual(below.isOverlapping, false)
    }

    func testSingleModelWarmUpMakesNoOverlapClaim() {
        // One model cannot overlap with anything — the report must stay silent
        // rather than report a concurrency problem.
        let profile = WarmUpProfile(wallClock: 0.41, spans: [span("whisper-base.en", 0.0, 0.41)])
        XCTAssertNil(profile.overlapEfficiency)
        XCTAssertNil(profile.isOverlapping)
        XCTAssertNil(profile.serializedSeconds)
    }

    func testEmptyProfileIsSafe() {
        let profile = WarmUpProfile(wallClock: 0, spans: [])
        XCTAssertEqual(profile.serialTotal, 0)
        XCTAssertNil(profile.slowest)
        XCTAssertNil(profile.overlapEfficiency)
        XCTAssertNil(profile.isOverlapping)
    }

    // MARK: - Recorder

    func testRecorderOrdersSpansByStart() {
        let recorder = WarmUpRecorder()
        recorder.record(modelID: "late", start: 0.3, end: 0.9)
        recorder.record(modelID: "early", start: 0.0, end: 0.5)
        let profile = recorder.profile(wallClock: 0.9)
        XCTAssertEqual(profile.spans.map(\.modelID), ["early", "late"])
        XCTAssertEqual(profile.spans[0].duration, 0.5, accuracy: 0.0001)
    }

    func testRecorderClockIsMonotonicFromZero() {
        let recorder = WarmUpRecorder()
        let first = recorder.now()
        let second = recorder.now()
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }

    // MARK: - Measurement statistics

    func testColdIsTheFirstIterationAndWarmTheMedianOfTheRest() {
        let m = WarmStartMeasurement(
            label: "bilingual",
            modelIDs: ["a", "b", "c"],
            iterations: [3.10, 0.56, 0.54, 0.55],
            profile: nil
        )
        XCTAssertEqual(m.cold ?? 0, 3.10, accuracy: 0.0001)
        XCTAssertEqual(m.warm ?? 0, 0.55, accuracy: 0.0001)
    }

    func testWarmIsNilWithOnlyAColdIteration() {
        let m = WarmStartMeasurement(label: "single-model", modelIDs: ["a"], iterations: [1.9], profile: nil)
        XCTAssertEqual(m.cold ?? 0, 1.9, accuracy: 0.0001)
        XCTAssertNil(m.warm, "a single iteration gives no warm number to report")
    }

    func testMedian() {
        XCTAssertEqual(Statistics.median([0.4]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(Statistics.median([0.5, 0.3, 0.4]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(Statistics.median([0.4, 0.2]), 0.3, accuracy: 0.0001)
        XCTAssertEqual(Statistics.median([]), 0)
    }

    // MARK: - Acceptance verdict (spec §7: ≤ 1.5×)

    private func comparison(baseline: [Double], bilingual: [Double]) -> WarmStartComparison {
        WarmStartComparison(
            baseline: WarmStartMeasurement(
                label: "single-model", modelIDs: ["whisper-base.en"], iterations: baseline, profile: nil
            ),
            bilingual: WarmStartMeasurement(
                label: "bilingual", modelIDs: ["a", "b", "c"], iterations: bilingual, profile: nil
            )
        )
    }

    func testRatioAgainstBudget() {
        let pass = comparison(baseline: [2.0, 0.40], bilingual: [3.0, 0.54])
        XCTAssertEqual(pass.ratio ?? 0, 1.35, accuracy: 0.0001)
        XCTAssertEqual(pass.meetsBudget, true)

        // Exactly at the budget passes — "≤ 1.5×".
        let boundary = comparison(baseline: [2.0, 0.40], bilingual: [3.0, 0.60])
        XCTAssertEqual(boundary.ratio ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(boundary.meetsBudget, true)

        let fail = comparison(baseline: [2.0, 0.40], bilingual: [3.0, 0.61])
        XCTAssertEqual(fail.meetsBudget, false)
    }

    func testRatioIsNilWithoutWarmIterationsOnBothSides() {
        let noWarm = comparison(baseline: [2.0], bilingual: [3.0, 0.54])
        XCTAssertNil(noWarm.ratio)
        XCTAssertNil(noWarm.meetsBudget, "unmeasured must not read as passing")

        let zeroBaseline = comparison(baseline: [2.0, 0.0], bilingual: [3.0, 0.54])
        XCTAssertNil(zeroBaseline.ratio)
    }

    // MARK: - Report

    private func measurement(
        _ label: String, _ ids: [String], _ iterations: [Double], _ profile: WarmUpProfile?
    ) -> WarmStartMeasurement {
        WarmStartMeasurement(label: label, modelIDs: ids, iterations: iterations, profile: profile)
    }

    func testTextReportFlagsSerializedWarmUp() {
        let serial = WarmUpProfile(
            wallClock: 1.16,
            spans: [
                span("whisper-tiny", 0.00, 0.18),
                span("whisper-small.en", 0.18, 0.61),
                span("nb-whisper-small", 0.61, 1.16),
            ]
        )
        let text = WarmUpReport.text(
            baseline: measurement("single-model", ["whisper-base.en"], [1.9, 0.40], nil),
            bilingual: measurement("bilingual", ["a", "b", "c"], [3.1, 1.16], serial)
        )
        XCTAssertTrue(text.contains("NOT overlapping"), text)
        XCTAssertTrue(text.contains("FAIL"), "1.16 / 0.40 = 2.9× is over budget:\n\(text)")
        XCTAssertTrue(text.contains("nb-whisper-small"), text)
    }

    func testTextReportPassesWhenConcurrentAndWithinBudget() {
        let concurrent = WarmUpProfile(
            wallClock: 0.55,
            spans: [
                span("whisper-tiny", 0.00, 0.18),
                span("whisper-small.en", 0.00, 0.43),
                span("nb-whisper-small", 0.00, 0.55),
            ]
        )
        let text = WarmUpReport.text(
            baseline: measurement("single-model", ["whisper-base.en"], [1.9, 0.40], nil),
            bilingual: measurement("bilingual", ["a", "b", "c"], [3.1, 0.55], concurrent)
        )
        XCTAssertTrue(text.contains("loads overlap"), text)
        XCTAssertTrue(text.contains("PASS"), text)
        XCTAssertFalse(text.contains("NOT overlapping"), text)
    }

    func testTextReportSaysSoWhenTheRatioIsNotComputable() {
        let text = WarmUpReport.text(
            baseline: measurement("single-model", ["whisper-base.en"], [1.9], nil),
            bilingual: measurement("bilingual", ["a", "b", "c"], [3.1], nil)
        )
        XCTAssertTrue(text.contains("not computable"), text)
        XCTAssertFalse(text.contains("PASS"), text)
    }

    func testJSONReportCarriesRatioAndOverlap() throws {
        let concurrent = WarmUpProfile(
            wallClock: 0.55,
            spans: [span("whisper-tiny", 0.0, 0.18), span("nb-whisper-small", 0.0, 0.55)]
        )
        let json = WarmUpReport.json(
            baseline: measurement("single-model", ["whisper-base.en"], [1.9, 0.40], nil),
            bilingual: measurement("bilingual", ["a", "b"], [3.1, 0.55], concurrent)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(try XCTUnwrap(root["ratio"] as? Double), 1.375, accuracy: 0.0001)
        XCTAssertEqual(root["meetsBudget"] as? Bool, true)
        XCTAssertEqual(root["budget"] as? Double, 1.5)

        let bilingual = try XCTUnwrap(root["bilingual"] as? [String: Any])
        let overlap = try XCTUnwrap(bilingual["overlap"] as? [String: Any])
        XCTAssertEqual(overlap["overlapping"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(overlap["spans"] as? [[String: Any]]).count, 2)
    }

    func testJSONReportUsesNullForUnmeasuredValues() throws {
        let json = WarmUpReport.json(
            baseline: measurement("single-model", ["whisper-base.en"], [1.9], nil),
            bilingual: measurement("bilingual", ["a", "b"], [3.1], nil)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertTrue(root["ratio"] is NSNull, "an unmeasured ratio must be null, not 0")
        XCTAssertTrue(root["meetsBudget"] is NSNull)
    }

    // MARK: - Preflight

    func testUndownloadedModelsAreReportedAsMissing() {
        // A model pointed at a folder that does not exist can never be warm.
        let phantom = TranscriptionModel(
            id: "phantom",
            displayName: "Phantom",
            engine: .whisperKit,
            whisperKitID: "phantom",
            sizeMB: 1,
            languages: ["no"],
            recommended: false,
            modelFolder: "/nonexistent/parrot-bench-fixture"
        )
        XCTAssertEqual(Bench.WarmUp.notDownloaded([phantom]).map(\.id), ["phantom"])
    }
}

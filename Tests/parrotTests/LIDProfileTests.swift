import XCTest
@testable import parrot

/// Tests for the LID latency harness's inputs, analysis and reporting — the
/// parts that decide whether LID latency is a fixed cost or tracks utterance
/// length, and whether it met the 30 ms budget. Pure arithmetic over recorded
/// timings, so no models, microphone or ANE needed.
final class LIDProfileTests: XCTestCase {
    private func cell(
        _ seconds: Double,
        _ millis: [Double],
        signal: String = "noise"
    ) -> LIDCell {
        LIDCell(
            signal: signal,
            seconds: seconds,
            sampleCount: Int(seconds * 16_000),
            millis: millis,
            detectedLanguage: nil
        )
    }

    private func measurement(
        _ cells: [LIDCell],
        stages: [LIDStageBreakdown] = [],
        optimized: Bool = true
    ) -> LIDMeasurement {
        LIDMeasurement(
            modelID: "whisper-tiny",
            sampleRate: 16_000,
            windowSamples: 480_000,
            coldMillis: 803,
            cells: cells,
            stages: stages,
            optimizedBuild: optimized
        )
    }

    // MARK: - Synthetic audio

    func testGeneratedAudioHasTheRequestedLength() {
        for signal in SyntheticAudio.Signal.allCases {
            XCTAssertEqual(SyntheticAudio.make(signal, seconds: 2).count, 32_000, "\(signal)")
            XCTAssertEqual(SyntheticAudio.make(signal, seconds: 0.6).count, 9_600, "\(signal)")
            XCTAssertEqual(SyntheticAudio.make(signal, seconds: 0).count, 0, "\(signal)")
        }
    }

    func testSilenceIsSilentAndOtherSignalsAreNot() {
        XCTAssertTrue(SyntheticAudio.make(.silence, seconds: 1).allSatisfy { $0 == 0 })
        // The other two must clear the daemon's silence gate (RMS 0.003), or
        // the sweep would be timing a path a real utterance never takes.
        for signal in [SyntheticAudio.Signal.noise, .tone] {
            let samples = SyntheticAudio.make(signal, seconds: 1)
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            XCTAssertGreaterThan(rms, Run.silenceRMSFloor, "\(signal)")
            XCTAssertTrue(samples.allSatisfy { abs($0) <= SyntheticAudio.amplitude + 0.001 }, "\(signal)")
        }
    }

    func testGeneratedAudioIsDeterministic() {
        // Two runs of the bench must feed the model bit-identical audio so
        // only the clock differs between them.
        for signal in SyntheticAudio.Signal.allCases {
            XCTAssertEqual(
                SyntheticAudio.make(signal, seconds: 0.5),
                SyntheticAudio.make(signal, seconds: 0.5),
                "\(signal)"
            )
        }
    }

    // MARK: - Cells and the budget

    func testCellStatistics() {
        let c = cell(5, [72.0, 66.0, 89.0, 70.0, 71.0])
        XCTAssertEqual(c.median, 71.0, accuracy: 0.001)
        XCTAssertEqual(c.fastest ?? 0, 66.0, accuracy: 0.001)
        XCTAssertEqual(c.slowest ?? 0, 89.0, accuracy: 0.001)
    }

    func testCellWithinBudgetPasses() {
        let c = cell(10, [24.0, 26.0, 25.0])
        XCTAssertEqual(c.meetsBudget, true)
        XCTAssertEqual(c.budgetRatio ?? 0, 25.0 / 30.0, accuracy: 0.001)
    }

    func testCellOverBudgetFails() {
        // The gh#20 observation: warm LID at 66-89 ms against a 30 ms budget.
        let c = cell(2, [72.0, 66.0, 75.0])
        XCTAssertEqual(c.meetsBudget, false)
        XCTAssertEqual(c.budgetRatio ?? 0, 72.0 / 30.0, accuracy: 0.001)
    }

    func testCellBeyondTheBudgetsLengthIsNotJudged() {
        // The budget is stated for utterances up to 10 s. A 30 s cell is
        // measured — it is what shows length does not matter — but claiming a
        // verdict on it would be inventing one.
        XCTAssertNil(cell(30, [52.0]).meetsBudget)
        XCTAssertNotNil(cell(30, [52.0]).budgetRatio)
    }

    func testCellWithNoTimingsHasNoVerdict() {
        let c = cell(5, [])
        XCTAssertNil(c.meetsBudget)
        XCTAssertNil(c.budgetRatio)
    }

    // MARK: - Scaling: fixed cost vs tracks length

    func testFlatLatencyIsCalledAFixedCost() {
        // What the harness exists to detect: 30x the audio, same latency.
        let s = LIDScaling(points: [
            LIDScalingPoint(seconds: 1, millis: 53.4),
            LIDScalingPoint(seconds: 2, millis: 53.8),
            LIDScalingPoint(seconds: 5, millis: 51.4),
            LIDScalingPoint(seconds: 10, millis: 52.0),
            LIDScalingPoint(seconds: 30, millis: 50.8),
        ])
        XCTAssertEqual(s.isFixedCost, true)
        XCTAssertEqual(s.fixedFraction ?? 0, 1.0, accuracy: 0.05)
        XCTAssertEqual(s.perSecondMillis ?? 99, 0.0, accuracy: 0.2)
        XCTAssertEqual(s.latencySpread ?? 0, 53.8 / 50.8, accuracy: 0.001)
        XCTAssertEqual(s.lengthSpread ?? 0, 30.0, accuracy: 0.001)
    }

    func testLatencyProportionalToLengthIsNotAFixedCost() {
        // The other outcome the ticket asks about: if the cost really were the
        // audio, a shorter window would buy time proportionally.
        let s = LIDScaling(points: [
            LIDScalingPoint(seconds: 1, millis: 6),
            LIDScalingPoint(seconds: 2, millis: 12),
            LIDScalingPoint(seconds: 5, millis: 30),
            LIDScalingPoint(seconds: 10, millis: 60),
        ])
        XCTAssertEqual(s.isFixedCost, false)
        XCTAssertEqual(s.fixedMillis ?? 99, 0.0, accuracy: 0.5)
        XCTAssertEqual(s.perSecondMillis ?? 0, 6.0, accuracy: 0.1)
    }

    func testMostlyFixedWithASmallLengthTermStillCountsAsFixed() {
        let s = LIDScaling(points: [
            LIDScalingPoint(seconds: 1, millis: 50),
            LIDScalingPoint(seconds: 10, millis: 55),
        ])
        XCTAssertEqual(s.isFixedCost, true)
        XCTAssertEqual(s.perSecondMillis ?? 0, 0.5556, accuracy: 0.01)
    }

    func testOneLengthCannotAnswerTheScalingQuestion() {
        // Several signals at a single length: no slope to fit, and saying
        // "fixed" from that would be a guess.
        let s = LIDScaling(points: [
            LIDScalingPoint(seconds: 10, millis: 52),
            LIDScalingPoint(seconds: 10, millis: 54),
        ])
        XCTAssertNil(s.isFixedCost)
        XCTAssertNil(s.fixedMillis)
        XCTAssertNil(s.perSecondMillis)
        XCTAssertNil(s.fixedFraction)
        XCTAssertNil(s.lengthSpread)
    }

    func testLatencyAtALengthPoolsSignals() {
        let s = LIDScaling(points: [
            LIDScalingPoint(seconds: 5, millis: 50),
            LIDScalingPoint(seconds: 5, millis: 54),
            LIDScalingPoint(seconds: 10, millis: 60),
        ])
        XCTAssertEqual(s.latency(at: 5) ?? 0, 52, accuracy: 0.001)
        XCTAssertNil(s.latency(at: 2))
    }

    // MARK: - Measurement roll-up

    func testMeasurementFailsWhenInScopeCellsAreOverBudget() {
        let m = measurement([
            cell(1, [54.3], signal: "noise"),
            cell(10, [54.0], signal: "noise"),
            cell(30, [54.2], signal: "noise"),
        ])
        XCTAssertEqual(m.meetsBudget, false)
        XCTAssertEqual(m.inScopeCells.count, 2)
        XCTAssertEqual(m.inScopeMedian ?? 0, 54.15, accuracy: 0.001)
        XCTAssertEqual(m.windowSeconds ?? 0, 30.0, accuracy: 0.001)
    }

    func testMeasurementWithOnlyOutOfScopeCellsHasNoVerdict() {
        // Unmeasured is not passing.
        let m = measurement([cell(30, [52.0], signal: "noise")])
        XCTAssertNil(m.meetsBudget)
        XCTAssertNil(m.inScopeMedian)
    }

    func testMeasurementPassesWhenEveryInScopeCellIsUnderBudget() {
        let m = measurement([cell(1, [12.0], signal: "noise"), cell(10, [18.0], signal: "noise")])
        XCTAssertEqual(m.meetsBudget, true)
    }

    // MARK: - Stage breakdown

    func testStageBreakdownResidualIsWhatTheStagesDoNotExplain() {
        let s = LIDStageBreakdown(
            seconds: 30,
            padMillis: [0.1],
            melMillis: [9.8],
            encodeMillis: [6.5],
            totalMillis: [48.7]
        )
        XCTAssertEqual(s.residual, 32.3, accuracy: 0.001)
        XCTAssertEqual(s.dominant?.name, "decode+overhead")
        XCTAssertEqual(s.dominant?.share ?? 0, 32.3 / 48.7, accuracy: 0.001)
    }

    func testStageBreakdownResidualNeverGoesNegative() {
        // Noise can put the summed stages above a full call; a stage that
        // gives time back would be a reporting artifact, not a measurement.
        let s = LIDStageBreakdown(
            seconds: 1, padMillis: [0.1], melMillis: [10], encodeMillis: [7], totalMillis: [15]
        )
        XCTAssertEqual(s.residual, 0)
        XCTAssertEqual(s.dominant?.name, "mel")
    }

    // MARK: - Option parsing

    func testDurationParsingSortsDeduplicatesAndTrims() throws {
        XCTAssertEqual(try LIDSweepInput.durations("1,2,5,10,30"), [1, 2, 5, 10, 30])
        XCTAssertEqual(try LIDSweepInput.durations(" 10 , 1 ,10"), [1, 10])
        XCTAssertEqual(try LIDSweepInput.durations("0.6"), [0.6])
    }

    func testDurationParsingRejectsNonsense() {
        XCTAssertThrowsError(try LIDSweepInput.durations("abc"))
        XCTAssertThrowsError(try LIDSweepInput.durations("0"))
        XCTAssertThrowsError(try LIDSweepInput.durations("-3"))
        XCTAssertThrowsError(try LIDSweepInput.durations("500"))
        XCTAssertThrowsError(try LIDSweepInput.durations(""))
    }

    func testSignalParsing() throws {
        XCTAssertEqual(try LIDSweepInput.signals("noise"), [.noise])
        XCTAssertEqual(try LIDSweepInput.signals("tone,silence"), [.tone, .silence])
        XCTAssertEqual(try LIDSweepInput.signals("all"), SyntheticAudio.Signal.allCases)
        XCTAssertEqual(try LIDSweepInput.signals("noise,noise"), [.noise])
        XCTAssertThrowsError(try LIDSweepInput.signals("speech"))
    }

    // MARK: - Report

    func testTextReportStatesTheFixedCostVerdictAndTheFailure() {
        let m = measurement(
            [cell(1, [54.3], signal: "noise"), cell(10, [54.0], signal: "noise"), cell(30, [54.2], signal: "noise")],
            stages: [LIDStageBreakdown(
                seconds: 30, padMillis: [0.1], melMillis: [9.8],
                encodeMillis: [6.5], totalMillis: [48.7]
            )]
        )
        let text = LIDReport.text(m)
        XCTAssertTrue(text.contains("FIXED COST"), text)
        XCTAssertTrue(text.contains("FAIL"), text)
        XCTAssertTrue(text.contains("not judged"), text)
        XCTAssertTrue(text.contains("480000 samples"), text)
        XCTAssertTrue(text.contains("stage breakdown"), text)
        // It must not claim anything about ANE residency, which it cannot see.
        XCTAssertTrue(text.contains("powermetrics"), text)
    }

    func testTextReportRefusesToPassOffADebugNumberAsAVerdict() {
        // The trap this ticket walked into: the field numbers came from an
        // unoptimized binary, where the Swift half of the call dominates.
        let m = measurement(
            [cell(1, [54.3]), cell(10, [54.0])],
            optimized: false
        )
        let text = LIDReport.text(m)
        XCTAssertTrue(text.contains("DEBUG"), text)
        XCTAssertTrue(text.contains("-c release"), text)
        XCTAssertTrue(text.contains("not a verdict on the shipped binary"), text)
        XCTAssertTrue(LIDReport.text(measurement([cell(1, [12.0])])).contains("release (optimized)"))
    }

    func testTextReportSaysWhenLatencyTracksLength() {
        let m = measurement([cell(1, [6.0], signal: "noise"), cell(10, [60.0], signal: "noise")])
        let text = LIDReport.text(m)
        XCTAssertTrue(text.contains("TRACKS LENGTH"), text)
    }

    func testTextReportRefusesAScalingVerdictFromOneLength() {
        let m = measurement([cell(10, [54.0], signal: "noise"), cell(10, [55.0], signal: "tone")])
        let text = LIDReport.text(m)
        XCTAssertTrue(text.contains("not computable"), text)
        XCTAssertFalse(text.contains("FIXED COST"), text)
    }

    func testJSONReportIsValidAndNullsWhatWasNotMeasured() throws {
        let m = measurement([cell(30, [52.0], signal: "noise")])
        let data = Data(LIDReport.json(m).utf8)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "whisper-tiny")
        XCTAssertTrue(root["meetsBudget"] is NSNull)
        XCTAssertTrue(root["inScopeMedianMillis"] is NSNull)
        let scaling = try XCTUnwrap(root["scaling"] as? [String: Any])
        XCTAssertTrue(scaling["isFixedCost"] is NSNull)
        XCTAssertEqual((root["cells"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Arms (gh#25)

    private func arm(_ arm: LIDArm, median: Double) -> LIDMeasurement {
        // One in-scope cell whose median is the number under test.
        LIDMeasurement(
            modelID: "whisper-tiny",
            sampleRate: 16_000,
            windowSamples: 480_000,
            coldMillis: nil,
            cells: [cell(5, [median])],
            arm: arm,
            residentModelIDs: arm.needsFullModelSet
                ? ["whisper-tiny", "nb-whisper-small", "whisper-small.en"]
                : ["whisper-tiny"]
        )
    }

    func testArmsAlwaysRunLidOnlyFirstWhateverOrderTheyWereAskedFor() throws {
        // A loaded CoreML pipeline cannot be unloaded, so the lid-only arm is
        // only honest before the other two models exist. Order is the harness's
        // to decide, not the caller's.
        XCTAssertEqual(try LIDSweepInput.arms("daemon,lid-only"), [.lidOnly, .daemon])
        XCTAssertEqual(try LIDSweepInput.arms("all"), [.lidOnly, .threeResident, .daemon])
        XCTAssertEqual(try LIDSweepInput.arms("daemon, daemon"), [.daemon])
        XCTAssertThrowsError(try LIDSweepInput.arms("resident"))
        XCTAssertThrowsError(try LIDSweepInput.arms(""))
    }

    func testUnknownArmNamesTheOnesThatExist() {
        let error = LIDSweepInput.ParseError.unknownArm("bilingual")
        XCTAssertTrue(error.description.contains("three-resident"), error.description)
        XCTAssertTrue(error.description.contains("all"), error.description)
    }

    func testEachAttributionTermIsTheOneChangeAboveIt() throws {
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 20), arm(.threeResident, median: 26),
                   arm(.daemon, median: 30)],
            observedDaemonMillis: 52
        )
        let a = try XCTUnwrap(c.attribution)
        XCTAssertEqual(a.baseline, 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(a.residencyCost), 6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(a.callPathCost), 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(a.unexplained), 22, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(a.gap), 32, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(a.explained), 10, accuracy: 0.001)
    }

    func testTheGapIsMeasuredAgainstTheLiveDaemonWhenOneWasGiven() throws {
        let arms = [arm(.lidOnly, median: 20), arm(.threeResident, median: 26),
                    arm(.daemon, median: 30)]
        // Without --observed there is nothing beyond the arms, so the gap stops
        // at the daemon arm and the remainder is unmeasured rather than zero.
        let bench = LIDComparison(arms: arms)
        let benchOnly = try XCTUnwrap(bench.attribution)
        XCTAssertEqual(try XCTUnwrap(benchOnly.gap), 10, accuracy: 0.001)
        XCTAssertNil(benchOnly.unexplained)
        XCTAssertNil(benchOnly.unexplainedShare)

        let live = LIDComparison(arms: arms, observedDaemonMillis: 52)
        XCTAssertEqual(try XCTUnwrap(live.attribution?.gap), 32, accuracy: 0.001)
    }

    func testResidencyWinsWhenTheResidentModelsCostMostOfTheGap() {
        // Deliberately short of the live number: an arm that reached it would
        // be a reproduction, and there would be no gap left to attribute.
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 15), arm(.threeResident, median: 34),
                   arm(.daemon, median: 36)],
            observedDaemonMillis: 52
        )
        XCTAssertEqual(c.attribution?.verdict, .residency)
        let text = LIDReport.text(c)
        XCTAssertTrue(text.contains("RESIDENT MODELS"), text)
        // The finding generalizes — the report has to say so, because it bears
        // on the memory item and on a third route.
        XCTAssertTrue(text.contains("memory acceptance item"), text)
    }

    func testCallPathWinsWhenTheDaemonPathCostsMostOfTheGap() {
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 15), arm(.threeResident, median: 16),
                   arm(.daemon, median: 36)],
            observedDaemonMillis: 52
        )
        XCTAssertEqual(c.attribution?.verdict, .callPath)
        XCTAssertTrue(LIDReport.text(c).contains("CALL PATH"))
    }

    func testANegativeTermIsSpreadNotASaving() throws {
        // The first real gh#25 run came out like this: the lid-only arm ran
        // first and slowest, so "residency" was negative. Loading a second
        // model cannot make LID faster — a negative term means the run-to-run
        // spread is wider than the effect, and it must not be dressed up as a
        // share of anything.
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 27.6), arm(.threeResident, median: 18.6),
                   arm(.daemon, median: 17.0)],
            observedDaemonMillis: 52
        )
        let a = try XCTUnwrap(c.attribution)
        XCTAssertEqual(try XCTUnwrap(a.residencyCost), -9.0, accuracy: 0.05)
        XCTAssertNil(a.residencyShare)
        XCTAssertNil(a.callPathShare)
        // A negative term contributes nothing to what was explained rather
        // than cancelling a real cost beside it.
        XCTAssertNil(a.explained)
        XCTAssertEqual(a.verdict, .unexplained)
        let text = LIDReport.text(c)
        XCTAssertTrue(text.contains("below run-to-run spread"), text)
        XCTAssertFalse(text.contains("-37%"), text)
    }

    func testAnArmThatLandsOnTheLiveNumberIsCalledAReproduction() throws {
        // The gh#25 answer: with --gap 10 the arms reach the daemon's ~52ms.
        // Once they do, the leftover gap is a few ms and dividing noise by it
        // would print enormous shares — so reproduction is checked first.
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 48.3), arm(.threeResident, median: 57.0),
                   arm(.daemon, median: 43.5)],
            observedDaemonMillis: 52
        )
        let a = try XCTUnwrap(c.attribution)
        XCTAssertEqual(try XCTUnwrap(a.reproduction), 43.5 / 52, accuracy: 0.001)
        XCTAssertTrue(a.reproducesDaemon)
        XCTAssertEqual(a.verdict, .reproducesDaemon)
        let text = LIDReport.text(c)
        XCTAssertTrue(text.contains("REPRODUCES THE DAEMON"), text)
        XCTAssertTrue(text.contains("84% of the live daemon"), text)
        // No share table, because there is nothing left to share out.
        XCTAssertFalse(text.contains("gap to attribute"), text)
    }

    func testAnArmNowhereNearTheLiveNumberIsNotAReproduction() {
        // gh#20's situation: the bench times something three times faster than
        // the thing it claims to model, and has to say so.
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 19.6), arm(.daemon, median: 17.0)],
            observedDaemonMillis: 52
        )
        XCTAssertFalse(c.attribution?.reproducesDaemon ?? true)
        XCTAssertTrue(LIDReport.text(c).contains("33% of the live daemon"))
    }

    func testReproductionNeedsALiveNumberToCompareAgainst() {
        let c = LIDComparison(arms: [arm(.lidOnly, median: 20), arm(.daemon, median: 22)])
        XCTAssertNil(c.attribution?.reproduction)
        XCTAssertFalse(c.attribution?.reproducesDaemon ?? true)
    }

    func testTheBenchSaysSoWhenItExplainsNoneOfTheGap() throws {
        // The outcome gh#25 has to be able to report: both hypotheses measured,
        // both small, most of the live latency still unaccounted for. That is a
        // finding, not a failure to produce one.
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 20), arm(.threeResident, median: 21),
                   arm(.daemon, median: 22)],
            observedDaemonMillis: 52
        )
        let a = try XCTUnwrap(c.attribution)
        XCTAssertEqual(a.verdict, .unexplained)
        XCTAssertEqual(try XCTUnwrap(a.unexplainedShare), 30.0 / 32.0, accuracy: 0.001)
        let text = LIDReport.text(c)
        XCTAssertTrue(text.contains("NEITHER"), text)
        // And it must name what it still cannot reach rather than implying the
        // remainder is a mystery with no known candidates.
        XCTAssertTrue(text.contains("microphone"), text)
        XCTAssertTrue(text.contains("powermetrics"), text)
    }

    func testASingleArmMakesNoAttributionClaim() {
        let c = LIDComparison(arms: [arm(.lidOnly, median: 20)])
        XCTAssertEqual(c.attribution?.verdict, .notAttributable)
        // With one arm and nothing to compare it to, the old single-arm report
        // is what gets printed — no attribution section at all.
        XCTAssertFalse(LIDReport.text(c).contains("attribution"))
    }

    func testAttributionNeedsTheBaselineArm() {
        // Every term is a difference from lid-only; without it there is nothing
        // to subtract from and the report has to say that rather than guess.
        let c = LIDComparison(
            arms: [arm(.threeResident, median: 26), arm(.daemon, median: 30)],
            observedDaemonMillis: 52
        )
        XCTAssertNil(c.attribution)
        let text = LIDReport.text(c)
        XCTAssertTrue(text.contains("not computable"), text)
        XCTAssertTrue(text.contains("--arms all"), text)
    }

    func testTheJudgedArmIsTheMostDaemonLikeOneThatRan() {
        XCTAssertEqual(
            LIDComparison(arms: [arm(.lidOnly, median: 20), arm(.daemon, median: 50)]).judgedArm?.arm,
            .daemon
        )
        XCTAssertEqual(LIDComparison(arms: [arm(.lidOnly, median: 20)]).judgedArm?.arm, .lidOnly)
        XCTAssertNil(LIDComparison(arms: []).judgedArm)
    }

    func testABackToBackSweepIsFlaggedAsUnlikeTheDaemon() {
        // Every call in a tight loop keeps the ANE clocked up; the daemon's are
        // seconds apart. A run that did not use --gap has to admit it.
        let hammered = LIDComparison(
            arms: [arm(.lidOnly, median: 20), arm(.daemon, median: 22)],
            observedDaemonMillis: 52
        )
        XCTAssertTrue(LIDReport.text(hammered).contains("--gap"))

        var spaced = arm(.lidOnly, median: 20)
        spaced.gapSeconds = 5
        var spacedDaemon = arm(.daemon, median: 22)
        spacedDaemon.gapSeconds = 5
        let report = LIDReport.text(
            LIDComparison(arms: [spaced, spacedDaemon], observedDaemonMillis: 52)
        )
        XCTAssertFalse(report.contains("Re-run with"), report)
        XCTAssertTrue(report.contains("5.0s idle before each timed call"), report)
    }

    func testJSONCarriesEveryArmAndTheAttribution() throws {
        let c = LIDComparison(
            arms: [arm(.lidOnly, median: 15), arm(.threeResident, median: 34),
                   arm(.daemon, median: 36)],
            observedDaemonMillis: 52
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(LIDReport.json(c).utf8)) as? [String: Any]
        )
        let arms = try XCTUnwrap(root["arms"] as? [[String: Any]])
        XCTAssertEqual(arms.map { $0["arm"] as? String }, ["lid-only", "three-resident", "daemon"])
        XCTAssertEqual((arms[1]["residentModels"] as? [String])?.count, 3)
        let attribution = try XCTUnwrap(root["attribution"] as? [String: Any])
        XCTAssertEqual(attribution["residencyMillis"] as? Double, 19)
        XCTAssertEqual(attribution["unexplainedMillis"] as? Double, 16)
        XCTAssertEqual(attribution["verdict"] as? String, "residency")
    }

    func testJSONNullsAnObservedNumberNobodyGave() throws {
        let c = LIDComparison(arms: [arm(.lidOnly, median: 20), arm(.daemon, median: 22)])
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(LIDReport.json(c).utf8)) as? [String: Any]
        )
        XCTAssertTrue(root["observedDaemonMillis"] is NSNull)
        let attribution = try XCTUnwrap(root["attribution"] as? [String: Any])
        XCTAssertTrue(attribution["unexplainedMillis"] is NSNull)
    }
}

import ArgumentParser
import Foundation
import WhisperKit

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure startup and routing costs.",
        subcommands: [WarmUp.self, LID.self]
    )

    /// Warm-start harness for spec §7: is the three-model bilingual warm start
    /// within 1.5× the single-model one, and do the three loads actually run
    /// concurrently?
    ///
    /// Each iteration builds a *fresh* pipeline set and times `warmUp()`, so
    /// nothing is cached inside the process between iterations. The first
    /// iteration is reported as "cold" and the median of the rest as "warm":
    /// only the first pays for cold page cache and CoreML compilation.
    ///
    /// "Cold" here means cold-in-process, not cold-from-boot — the OS page
    /// cache and CoreML's on-disk compilation cache survive between runs. For
    /// a genuinely cold number, `sudo purge` first and use --iterations 1.
    struct WarmUp: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "warmup",
            abstract: "Time single-model vs bilingual (three-model) warm start."
        )

        enum Target: String, ExpressibleByArgument, CaseIterable {
            case both, single, bilingual
        }

        @Option(name: .long, help: "Warm-ups per configuration; the first is the cold one.")
        var iterations: Int = 3

        @Option(name: .long, help: "Which configurations to measure.")
        var only: Target = .both

        @Option(name: .long, help: "Single-model baseline. Defaults to the recommended model.")
        var model: String?

        @Option(name: .customLong("no-model"), help: "Bilingual: model for the Norwegian route.")
        var noModel: String = BilingualConfiguration.defaultNorwegianModelID

        @Option(name: .customLong("en-model"), help: "Bilingual: model for the English route.")
        var enModel: String = BilingualConfiguration.defaultEnglishModelID

        @Flag(name: .long, help: "Measure even if a model still has to be downloaded (the cold number then includes the download).")
        var allowDownload: Bool = false

        @Flag(name: .long, help: "Emit machine-readable JSON instead of the text report.")
        var json: Bool = false

        func validate() throws {
            if iterations < 1 {
                throw ValidationError("--iterations must be at least 1.")
            }
        }

        func run() throws {
            let baselineModel: TranscriptionModel?
            if only == .bilingual {
                baselineModel = nil
            } else if let id = model {
                guard let m = ModelRegistry.find(id) else {
                    throw fail("unknown model: \(id) — run `parrot models list` to see options.")
                }
                baselineModel = m
            } else {
                guard let m = ModelRegistry.recommended() else {
                    throw fail("no models registered")
                }
                baselineModel = m
            }

            let bilingualConfig: BilingualConfiguration?
            if only == .single {
                bilingualConfig = nil
            } else {
                do {
                    bilingualConfig = try BilingualConfiguration(
                        norwegianModelID: noModel, englishModelID: enModel
                    )
                } catch {
                    throw fail("\(error)")
                }
            }

            // Warm start is only meaningful once the models are on disk. A run
            // that silently folds a multi-hundred-megabyte download into the
            // number would look like a measurement and be worthless as one.
            let needed = (baselineModel.map { [$0] } ?? []) + (bilingualConfig?.models ?? [])
            let missing = Self.notDownloaded(needed)
            if !missing.isEmpty, !allowDownload {
                var lines = ["not measured — these models are not on disk:"]
                for m in missing {
                    lines.append("  ✗ \(m.id)  → parrot models download \(m.id)")
                }
                lines.append("")
                lines.append("warm start is only meaningful once every model is downloaded.")
                lines.append("pass --allow-download to measure anyway (the cold number then "
                    + "includes the download and is not a warm start).")
                throw fail(lines.joined(separator: "\n"))
            }

            let iterations = self.iterations
            let box = ResultBox<(WarmStartMeasurement?, WarmStartMeasurement?)>()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    var baseline: WarmStartMeasurement?
                    if let baselineModel {
                        baseline = try await Self.measure(
                            label: "single-model",
                            modelIDs: [baselineModel.id],
                            iterations: iterations
                        ) { recorder in
                            WhisperKitTranscriber(model: baselineModel, recorder: recorder)
                        }
                    }
                    var bilingual: WarmStartMeasurement?
                    if let bilingualConfig {
                        bilingual = try await Self.measure(
                            label: "bilingual",
                            modelIDs: bilingualConfig.models.map(\.id),
                            iterations: iterations
                        ) { recorder in
                            RoutingTranscriber(configuration: bilingualConfig, recorder: recorder)
                        }
                    }
                    box.set(.success((baseline, bilingual)))
                } catch {
                    box.set(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch box.get() {
            case let .failure(error):
                throw fail("warm-up failed: \(error)")
            case let .success((baseline, bilingual)):
                if json {
                    print(WarmUpReport.json(baseline: baseline, bilingual: bilingual))
                } else {
                    print(WarmUpReport.text(baseline: baseline, bilingual: bilingual))
                    print("")
                    print("cold = first warm-up in this process; the OS page cache and CoreML's")
                    print("compilation cache survive between runs. For a cold-from-boot number,")
                    print("run `sudo purge` first and use --iterations 1.")
                }
            case .none:
                throw fail("warm-up produced no result")
            }
        }

        /// Times `iterations` warm-ups, each on a freshly constructed pipeline
        /// set so no in-process state carries over.
        private static func measure(
            label: String,
            modelIDs: [String],
            iterations: Int,
            make: @Sendable (WarmUpRecorder) -> any Transcriber
        ) async throws -> WarmStartMeasurement {
            var times: [Double] = []
            var lastProfile: WarmUpProfile?
            for i in 0..<iterations {
                let recorder = WarmUpRecorder()
                let transcriber = make(recorder)
                let started = recorder.now()
                try await transcriber.warmUp()
                let elapsed = recorder.now() - started
                times.append(elapsed)
                lastProfile = recorder.profile(wallClock: elapsed)
                FileHandle.standardError.write(Data(
                    String(format: "◐ %@ iteration %d/%d · %.3fs\n",
                           label, i + 1, iterations, elapsed).utf8
                ))
            }
            return WarmStartMeasurement(
                label: label, modelIDs: modelIDs, iterations: times, profile: lastProfile
            )
        }

        /// Models the doctor cannot find on disk. A warning ("not downloaded")
        /// counts as missing here — for a warm start it is disqualifying.
        static func notDownloaded(_ models: [TranscriptionModel]) -> [TranscriptionModel] {
            models.filter {
                if case .ok = DoctorReport.checkModelDownloaded($0).status { return false }
                return true
            }
        }

        private func fail(_ message: String) -> ExitCode {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return ExitCode(1)
        }
    }

    /// LID latency harness for spec §7: is the language-identification pass
    /// within its 30 ms budget, and does its cost track the utterance or the
    /// model's fixed input window? (gh#20 — measured LID is 66-89 ms warm.)
    ///
    /// LID latency depends on how much audio the model is handed, not on what
    /// the audio says, so the sweep runs on generated signals: no microphone,
    /// no fixtures, no Norwegian speaker. That also bounds what it can answer
    /// — it measures latency, never accuracy.
    ///
    /// gh#25: a `lid-only` pass at 19.6 ms did not predict the live daemon's
    /// ~52 ms on the same release build. `--arms` runs the sweep again with the
    /// daemon's full three-model set resident, and again through the daemon's
    /// own call path, so the difference between those situations is measured
    /// rather than guessed at.
    struct LID: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "lid",
            abstract: "Time the language-identification pass across utterance lengths."
        )

        @Option(name: .long, help: "Utterance lengths in seconds, comma-separated.")
        var durations: String = "1,2,5,10,30"

        @Option(name: .long, help: "Synthetic signals to time: silence, noise, tone, or all.")
        var signals: String = "noise"

        @Option(name: .long, help: "Timed calls per cell. One cold call is timed separately, before the sweep.")
        var iterations: Int = 5

        @Option(name: .long, help: "What to hold resident and which call path to time: lid-only, three-resident, daemon, or all.")
        var arms: String = LIDArm.lidOnly.rawValue

        @Option(name: .long, help: "Idle seconds before each timed call. The daemon's calls are seconds apart; a back-to-back loop is not.")
        var gap: Double = 0

        @Option(name: .long, help: "Median ◐ lid latency from a live daemon session, in ms — the bench cannot measure it itself.")
        var observed: Double?

        @Option(name: .customLong("lid-model"), help: "Model used for the LID pass.")
        var lidModel: String = BilingualConfiguration.lidModelID

        @Option(name: .customLong("no-model"), help: "Norwegian model held resident by the three-model arms.")
        var noModel: String = BilingualConfiguration.defaultNorwegianModelID

        @Option(name: .customLong("en-model"), help: "English model held resident by the three-model arms.")
        var enModel: String = BilingualConfiguration.defaultEnglishModelID

        @Flag(name: .long, help: "Also split each call into pad / mel / encoder / decode.")
        var stages: Bool = false

        @Flag(name: .long, help: "Measure even if a model still has to be downloaded.")
        var allowDownload: Bool = false

        @Flag(name: .long, help: "Emit machine-readable JSON instead of the text report.")
        var json: Bool = false

        func validate() throws {
            if iterations < 1 {
                throw ValidationError("--iterations must be at least 1.")
            }
            if gap < 0 || gap > LIDSweepInput.maxGapSeconds {
                throw ValidationError(String(
                    format: "--gap must be between 0 and %g seconds.", LIDSweepInput.maxGapSeconds
                ))
            }
            if let observed, observed <= 0 {
                throw ValidationError("--observed is a latency in milliseconds; it must be positive.")
            }
            do {
                _ = try LIDSweepInput.durations(durations)
                _ = try LIDSweepInput.signals(signals)
                _ = try LIDSweepInput.arms(arms)
            } catch let error as LIDSweepInput.ParseError {
                throw ValidationError(error.description)
            }
        }

        func run() throws {
            guard let model = ModelRegistry.find(lidModel) else {
                throw fail("unknown model: \(lidModel) — run `parrot models list --all` to see options.")
            }
            guard model.languages.contains("multi") else {
                throw fail("\(model.id) is not multilingual — language detection needs a "
                    + "multilingual model (the default is \(BilingualConfiguration.lidModelID)).")
            }

            let arms = try LIDSweepInput.arms(self.arms)
            var bilingual: BilingualConfiguration?
            if arms.contains(where: \.needsFullModelSet) {
                // The three-model arms route through RoutingTranscriber, which
                // always identifies on `BilingualConfiguration.lidModelID`. If
                // --lid-model says otherwise the arms would not be timing the
                // same model, and the difference between them would mean nothing.
                guard model.id == BilingualConfiguration.lidModelID else {
                    throw fail("--lid-model \(model.id) cannot be compared against the "
                        + "three-model arms: bilingual mode always identifies on "
                        + "\(BilingualConfiguration.lidModelID), so the arms would be timing "
                        + "different models.\n"
                        + "  → drop --lid-model, or run --arms lid-only.")
                }
                do {
                    bilingual = try BilingualConfiguration(
                        norwegianModelID: noModel, englishModelID: enModel
                    )
                } catch {
                    throw fail("\(error)")
                }
            }

            let needed = bilingual?.models ?? [model]
            let missing = Bench.WarmUp.notDownloaded(needed)
            if !missing.isEmpty, !allowDownload {
                var lines = ["not measured — these models are not on disk:"]
                for m in missing {
                    lines.append("  ✗ \(m.id)  → parrot models download \(m.id)")
                }
                lines.append("pass --allow-download to download them as part of the run.")
                throw fail(lines.joined(separator: "\n"))
            }

            let lengths = try LIDSweepInput.durations(durations)
            let signalSet = try LIDSweepInput.signals(signals)
            let plan = SweepPlan(
                lidModel: model,
                bilingual: bilingual,
                arms: arms,
                lengths: lengths,
                signals: signalSet,
                iterations: iterations,
                stages: stages,
                gapSeconds: gap
            )
            let observed = self.observed
            let box = ResultBox<LIDComparison>()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    var comparison = try await Self.compare(plan)
                    comparison.observedDaemonMillis = observed
                    box.set(.success(comparison))
                } catch {
                    box.set(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()

            switch box.get() {
            case let .failure(error):
                throw fail("lid bench failed: \(error)")
            case let .success(comparison):
                print(json ? LIDReport.json(comparison) : LIDReport.text(comparison))
            case .none:
                throw fail("lid bench produced no result")
            }
        }

        /// Everything the sweep needs, gathered so it crosses the concurrency
        /// boundary as one value.
        private struct SweepPlan: @unchecked Sendable {
            let lidModel: TranscriptionModel
            let bilingual: BilingualConfiguration?
            let arms: [LIDArm]
            let lengths: [Double]
            let signals: [SyntheticAudio.Signal]
            let iterations: Int
            let stages: Bool
            let gapSeconds: Double
        }

        /// Runs each requested arm in turn, in one process.
        ///
        /// Order is forced by `LIDSweepInput.arms` and it matters: a loaded
        /// CoreML pipeline cannot be unloaded, so `lid-only` is only honest
        /// before the other two models exist. The standalone LID pipeline is
        /// released before the router is built, or whisper-tiny would be
        /// resident twice and the residency term would count a model the daemon
        /// does not hold.
        private static func compare(_ plan: SweepPlan) async throws -> LIDComparison {
            var standalone: WhisperKit?
            var router: RoutingTranscriber?
            var results: [LIDMeasurement] = []

            for arm in plan.arms {
                FileHandle.standardError.write(Data(
                    "◐ arm \(arm.rawValue) — \(arm.summary)\n".utf8
                ))
                let pipeline: WhisperKit
                let residentIDs: [String]
                let call: LIDCall

                switch arm {
                case .lidOnly:
                    let loaded = try await LIDPipeline.load(plan.lidModel)
                    standalone = loaded
                    pipeline = loaded
                    residentIDs = [plan.lidModel.id]
                    call = { try await loaded.detectLangauge(audioArray: $0).language }

                case .threeResident, .daemon:
                    guard let bilingual = plan.bilingual else {
                        throw LIDBenchError.stageFailed(
                            "arm \(arm.rawValue) needs the bilingual model set"
                        )
                    }
                    if router == nil {
                        standalone = nil
                        let built = RoutingTranscriber(configuration: bilingual)
                        try await built.warmUp()
                        router = built
                    }
                    guard let router, let resident = await router.residentLIDPipeline() else {
                        throw LIDBenchError.stageFailed("routing transcriber has no LID pipeline")
                    }
                    pipeline = resident
                    residentIDs = bilingual.models.map(\.id)
                    if arm == .threeResident {
                        call = { try await resident.detectLangauge(audioArray: $0).language }
                    } else {
                        // identifyLanguage swallows a LID failure by design —
                        // the daemon falls through to the default route rather
                        // than dropping the utterance. The bench must not: a
                        // failing call is fast, and timing it would report a
                        // flattering median for something that never worked.
                        call = {
                            let outcome = try await router.identifyLanguage($0)
                            if let failure = outcome.failure {
                                throw LIDBenchError.stageFailed("detectLangauge failed: \(failure)")
                            }
                            return outcome.language
                        }
                    }
                }

                results.append(try await sweep(
                    arm: arm,
                    plan: plan,
                    pipeline: pipeline,
                    residentModelIDs: residentIDs,
                    call: call
                ))
            }
            // Keep both alive until every arm is done: releasing mid-sweep
            // would change what is resident under a later arm.
            withExtendedLifetime((standalone, router)) {}
            return LIDComparison(arms: results)
        }

        /// Pays the cold call once, then times every (signal, length) cell
        /// against the same warm pipeline — the state the daemon is in for
        /// every utterance after the first.
        private static func sweep(
            arm: LIDArm,
            plan: SweepPlan,
            pipeline: WhisperKit,
            residentModelIDs: [String],
            call: LIDCall
        ) async throws -> LIDMeasurement {
            // The first call after load pays for lazy CoreML setup — the 803 ms
            // outlier in the gh#20 session log. Timed once, reported once, and
            // kept out of every cell. Only the first arm sees a real cold call;
            // later arms share the process and report their own anyway, because
            // "cold" for them is a different and still interesting thing.
            let longest = plan.lengths.max() ?? 30
            let cold = try await time {
                _ = try await call(SyntheticAudio.make(.noise, seconds: longest))
            }
            FileHandle.standardError.write(Data(String(
                format: "◐ lid cold · %.1fms\n", cold
            ).utf8))

            var cells: [LIDCell] = []
            for signal in plan.signals {
                for seconds in plan.lengths {
                    let audio = SyntheticAudio.make(signal, seconds: seconds)
                    var millis: [Double] = []
                    var detected: String?
                    for _ in 0..<plan.iterations {
                        try await idle(plan.gapSeconds)
                        let elapsed = try await time {
                            detected = try await call(audio)
                        }
                        millis.append(elapsed)
                    }
                    let cell = LIDCell(
                        signal: signal.rawValue,
                        seconds: seconds,
                        sampleCount: audio.count,
                        millis: millis,
                        detectedLanguage: detected
                    )
                    cells.append(cell)
                    FileHandle.standardError.write(Data(String(
                        format: "◐ lid %@ %.1fs · median %.1fms (%d calls)\n",
                        signal.rawValue, seconds, cell.median, millis.count
                    ).utf8))
                }
            }

            var breakdowns: [LIDStageBreakdown] = []
            if plan.stages {
                for seconds in plan.lengths {
                    breakdowns.append(try await stageBreakdown(
                        pipeline: pipeline,
                        call: call,
                        signal: plan.signals.first ?? .noise,
                        seconds: seconds,
                        iterations: plan.iterations
                    ))
                }
            }

            return LIDMeasurement(
                modelID: plan.lidModel.id,
                sampleRate: AudioCapture.targetSampleRate,
                windowSamples: pipeline.featureExtractor.windowSamples,
                coldMillis: cold,
                cells: cells,
                stages: breakdowns,
                optimizedBuild: optimizedBuild,
                arm: arm,
                residentModelIDs: residentModelIDs,
                gapSeconds: plan.gapSeconds
            )
        }

        /// Waits `seconds` before the next timed call. A tight loop keeps the
        /// ANE clocked up and the weights hot; the daemon's calls are seconds
        /// or minutes apart. `--gap` is how that difference gets measured
        /// rather than assumed away.
        private static func idle(_ seconds: Double) async throws {
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        /// Times `detectLangauge`'s own stages — pad, mel, encoder — through
        /// the same public pipeline objects the real call uses, plus a full
        /// call for the residual. Reproduces `WhisperKit.detectLangauge`'s
        /// prologue exactly: pad or trim to the feature extractor's window,
        /// mel, encode.
        ///
        /// `call` is the arm's own full call, so on the `daemon` arm the
        /// residual carries the daemon's call path as well as the decode step
        /// — which is the point of splitting the arms in the first place.
        private static func stageBreakdown(
            pipeline: WhisperKit,
            call: LIDCall,
            signal: SyntheticAudio.Signal,
            seconds: Double,
            iterations: Int
        ) async throws -> LIDStageBreakdown {
            let audio = SyntheticAudio.make(signal, seconds: seconds)
            // Same fallback WhisperKit uses when the model does not declare one.
            let window = pipeline.featureExtractor.windowSamples ?? 480_000
            var pad: [Double] = []
            var mel: [Double] = []
            var encode: [Double] = []
            var total: [Double] = []
            for _ in 0..<iterations {
                var padded: (any AudioProcessorOutputType)?
                pad.append(await time {
                    padded = pipeline.audioProcessor.padOrTrim(
                        fromArray: audio, startAt: 0, toLength: window
                    )
                })
                guard let padded else {
                    throw LIDBenchError.stageFailed("padOrTrim returned nothing")
                }
                var features: (any FeatureExtractorOutputType)?
                mel.append(try await time {
                    features = try await pipeline.featureExtractor.logMelSpectrogram(fromAudio: padded)
                })
                guard let features else {
                    throw LIDBenchError.stageFailed("mel spectrogram returned nothing")
                }
                encode.append(try await time {
                    _ = try await pipeline.audioEncoder.encodeFeatures(features)
                })
                total.append(try await time {
                    _ = try await call(audio)
                })
            }
            let breakdown = LIDStageBreakdown(
                seconds: seconds, padMillis: pad, melMillis: mel,
                encodeMillis: encode, totalMillis: total
            )
            FileHandle.standardError.write(Data(String(
                format: "◐ lid stages %.1fs · pad %.1f · mel %.1f · encode %.1f · total %.1fms\n",
                seconds, breakdown.pad, breakdown.mel, breakdown.encode, breakdown.total
            ).utf8))
            return breakdown
        }

        /// Whether this binary was compiled with optimization. `swift run` and
        /// `swift build` produce a debug binary, where the Swift half of the
        /// LID call costs several times what it does in a release build — the
        /// difference between failing and meeting the budget, so the report
        /// says which one it measured.
        private static var optimizedBuild: Bool {
            #if DEBUG
            return false
            #else
            return true
            #endif
        }

        /// Milliseconds on the monotonic clock — `Date` can step under NTP and
        /// these spans are tens of milliseconds.
        private static func time(_ body: () async throws -> Void) async rethrows -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            try await body()
            return Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e6
        }

        private func fail(_ message: String) -> ExitCode {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return ExitCode(1)
        }
    }
}

/// One arm's way of running a single LID pass: hand it audio, get the detected
/// language back. `lid-only` and `three-resident` bind this to
/// `WhisperKit.detectLangauge`; `daemon` binds it to
/// `RoutingTranscriber.identifyLanguage`. Everything else about the sweep is
/// identical across arms, so the closure is the whole difference between them.
typealias LIDCall = @Sendable ([Float]) async throws -> String?

enum LIDBenchError: Error, CustomStringConvertible {
    /// A stage of the hand-rolled `detectLangauge` breakdown returned nothing.
    case stageFailed(String)

    var description: String {
        switch self {
        case let .stageFailed(what):
            return "stage breakdown failed: \(what)"
        }
    }
}

/// Carries the async result back to ParsableCommand's synchronous `run()`
/// without capturing a mutable variable across a concurrency boundary.
private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ newValue: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

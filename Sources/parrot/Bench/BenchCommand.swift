import ArgumentParser
import Foundation

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure startup and routing costs.",
        subcommands: [WarmUp.self]
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
            let box = OutcomeBox()
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
}

/// Carries the async result back to ParsableCommand's synchronous `run()`
/// without capturing a mutable variable across a concurrency boundary.
private final class OutcomeBox: @unchecked Sendable {
    typealias Value = Result<(WarmStartMeasurement?, WarmStartMeasurement?), Error>

    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self, Bench.self],
        defaultSubcommand: Run.self
    )
}

extension InputDevicePolicy.Preference: ExpressibleByArgument {
    init?(argument: String) {
        guard let parsed = InputDevicePolicy.Preference.parse(argument) else { return nil }
        self = parsed
    }

    var defaultValueDescription: String { "auto" }
}

/// Shared help text — `run`, `doctor` and `install` all take this flag and
/// should describe it identically.
let inputDeviceHelp = ArgumentHelp(
    "Microphone to record from: a device name, or 'default' for the system default input.",
    discussion: """
        Default is 'auto': if the system default input is a Bluetooth headset \
        and any other input exists, parrot records from the other one. Opening \
        a Bluetooth mic drops the headset to HFP — 16 kHz mono, and audibly \
        distorted for whatever it is playing.
        """
)

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    /// Captures with RMS below this are treated as silence/noise-only and
    /// skipped before LID — language detection on silence is meaningless.
    static let silenceRMSFloor: Float = 0.003

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Skip the startup doctor report.",
            discussion: """
                Accessibility is still checked: without it there is no hotkey \
                tap and nothing else parrot does can matter, so failing before \
                a gigabyte of models loads is the only sensible order.
                """
        )
    )
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Flag(name: .long, help: "Bilingual mode: route each utterance to NB-Whisper (Norwegian) or English Whisper via language detection.")
    var bilingual: Bool = false

    @Option(name: .customLong("no-model"), help: "Bilingual: model for the Norwegian route.")
    var noModel: String = BilingualConfiguration.defaultNorwegianModelID

    @Option(name: .customLong("en-model"), help: "Bilingual: model for the English route.")
    var enModel: String = BilingualConfiguration.defaultEnglishModelID

    @Option(name: .customLong("en-threshold"), help: "Bilingual: LID confidence gate for the English route (0-1).")
    var enThreshold: Float = RoutingPolicy.defaultEnglishThreshold

    @Option(name: .customLong("input-device"), help: inputDeviceHelp)
    var inputDevice: InputDevicePolicy.Preference = .auto

    func validate() throws {
        if bilingual, model != nil {
            throw ValidationError("--model conflicts with --bilingual; use --no-model / --en-model instead.")
        }
        if !bilingual {
            if noModel != BilingualConfiguration.defaultNorwegianModelID
                || enModel != BilingualConfiguration.defaultEnglishModelID
                || enThreshold != RoutingPolicy.defaultEnglishThreshold
            {
                throw ValidationError("--no-model / --en-model / --en-threshold require --bilingual.")
            }
        }
        if bilingual, !(0...1).contains(enThreshold) {
            throw ValidationError("--en-threshold must be between 0 and 1.")
        }
    }

    /// Settle the Accessibility question before anything expensive happens.
    ///
    /// Without the grant the hotkey tap can't be created and the daemon is
    /// useless, so discovering it after warm-up means a gigabyte of models
    /// loaded for nothing — once per launchd restart (gh#35). Prompting is a
    /// decision made here, once, from a record that outlives the process:
    /// asking on every start is what turned one dialog into seventeen.
    private func ensureAccessibility(session: SessionKind) throws {
        let store = AccessibilityStore.shared
        let subject = AccessibilitySubjectResolver.resolve()

        if AccessibilityTrust.isTrusted() {
            store.noteGranted(subject: subject)
            return
        }

        let binary = BinaryIdentity.current()
        if case .ask = AccessibilityPrompting.decide(
            record: store.load(),
            binary: binary,
            session: session
        ) {
            FileHandle.standardError.write(Data("asking macOS for accessibility access...\n".utf8))
            AccessibilityTrust.requestPrompt()
            // Recorded before waiting: a dialog the user walks away from is
            // still a spent prompt, and must not be reopened by the next start.
            store.notePrompted(binary: binary)
            if AccessibilityTrust.waitForTrust(seconds: AccessibilityTrust.promptGrace) {
                store.noteGranted(subject: subject)
                return
            }
        }

        let diagnosis = AccessibilityDiagnosis.classify(
            trusted: false,
            record: store.load(),
            binary: binary,
            session: session
        )
        let lines = AccessibilityGuidance.daemonFailure(
            for: diagnosis,
            subject: subject,
            session: session
        )
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        throw ExitCode(AccessibilityGuidance.daemonExitCode(for: session))
    }

    func run() throws {
        let session = SessionKind.detect()
        try ensureAccessibility(session: session)

        // Resolve models first so doctor can check they're downloaded.
        let transcriber: any Transcriber
        let routing: RoutingTranscriber?
        let activeModels: [TranscriptionModel]
        let menuBarModelID: String
        let menuBarTitle: String?
        let silenceFloor: Float?

        if bilingual {
            let config: BilingualConfiguration
            do {
                config = try BilingualConfiguration(
                    norwegianModelID: noModel,
                    englishModelID: enModel,
                    englishThreshold: enThreshold
                )
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                throw ExitCode(1)
            }
            let r = RoutingTranscriber(configuration: config)
            transcriber = r
            routing = r
            activeModels = config.models
            menuBarModelID = r.modelID
            // Bird icon only, same as single-model mode — the pair of models is
            // still named on the menu's `model:` line for anyone who wants it.
            menuBarTitle = nil
            silenceFloor = Self.silenceRMSFloor
        } else {
            let chosenModel: TranscriptionModel
            if let id = model {
                guard let m = ModelRegistry.find(id) else {
                    FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                    FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                    throw ExitCode(1)
                }
                chosenModel = m
            } else {
                guard let m = ModelRegistry.recommended() else {
                    FileHandle.standardError.write(Data("no models registered\n".utf8))
                    throw ExitCode(1)
                }
                chosenModel = m
            }
            transcriber = WhisperKitTranscriber(model: chosenModel)
            routing = nil
            activeModels = [chosenModel]
            menuBarModelID = chosenModel.id
            menuBarTitle = nil
            silenceFloor = nil
        }

        if !skipDoctor {
            let checks = DoctorReport.run(models: activeModels, inputPreference: inputDevice)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: debugHotkey)
        let capture = AudioCapture()
        capture.inputPreference = inputDevice

        // Resolve once up front so the log says which mic we're on before
        // anyone has spoken into it, and so a bad --input-device is visible at
        // startup rather than on the first Fn press.
        let initialInput = AudioDevices.resolve(preference: inputDevice)
        FileHandle.standardError.write(Data(initialInput.logLine.utf8))
        if initialInput.isFailure {
            let available = AudioDevices.inputDevices().map { $0.name }
            let hint = available.isEmpty
                ? "  no input devices found.\n"
                : "  available: \(available.joined(separator: ", "))\n"
            FileHandle.standardError.write(Data(hint.utf8))
        }
        capture.primeInputSelection(initialInput)
        capture.onInputChange = { selection in
            FileHandle.standardError.write(Data(selection.logLine.utf8))
        }

        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: menuBarModelID, buttonTitle: menuBarTitle)
        }

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    do {
                        try capture.start()
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }
                case .released:
                    let samples = capture.stop()
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        let path = "/tmp/parrot-last.wav"
                        do {
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                        }
                    }
                    guard !samples.isEmpty else {
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    // Silence gate: LID on noise-only captures is meaningless,
                    // and there is nothing worth decoding either.
                    if let silenceFloor, rms < silenceFloor {
                        FileHandle.standardError.write(Data(
                            String(format: "∅ silence (rms %.3f < %.3f) · skipped\n", rms, silenceFloor).utf8
                        ))
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    Task {
                        let started = Date()
                        do {
                            let text = try await transcriber.transcribe(samples)
                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                            ))
                            let decision: String?
                            if let routing {
                                decision = await routing.lastDecision
                            } else {
                                decision = nil
                            }
                            await MainActor.run {
                                TextInjector.inject(text)
                                overlay?.hide()
                                menuBar.setRecording(false)
                                if let decision {
                                    menuBar.setLastDecision(decision)
                                }
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            // The gate above already settled permissions, so reaching here
            // normally means something else went wrong — but the grant can also
            // be revoked in the seconds between. Restarting fixes neither, and
            // under launchd it would loop, so exit the same way either way.
            if !AccessibilityTrust.isTrusted() {
                let lines = AccessibilityGuidance.daemonFailure(
                    for: AccessibilityDiagnosis.classify(
                        trusted: false,
                        record: AccessibilityStore.shared.load(),
                        binary: BinaryIdentity.current(),
                        session: session
                    ),
                    subject: AccessibilitySubjectResolver.resolve(),
                    session: session
                )
                FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            } else {
                FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            }
            throw ExitCode(AccessibilityGuidance.daemonExitCode(for: session))
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data("listening on fn hold · model: \(menuBarModelID) · ^C to quit\n".utf8))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    @Flag(name: .long, help: "Also check that the bilingual model set is downloaded.")
    var bilingual: Bool = false

    @Option(name: .long, help: "Also check that this model is downloaded.")
    var model: String?

    @Option(name: .customLong("input-device"), help: inputDeviceHelp)
    var inputDevice: InputDevicePolicy.Preference = .auto

    func run() throws {
        var models: [TranscriptionModel] = []
        if bilingual {
            do {
                models = try BilingualConfiguration().models
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                throw ExitCode(1)
            }
        } else if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                throw ExitCode(1)
            }
            models = [m]
        } else if let m = ModelRegistry.recommended() {
            models = [m]
        }
        let checks = DoctorReport.run(
            models: models,
            inputPreference: inputDevice,
            includeAgent: true
        )
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self, Migrate.self]
    )

    struct List: ParsableCommand {
        @Flag(name: .long, help: "Include hidden/internal models (e.g. the LID model).")
        var all: Bool = false

        func run() throws {
            for m in ModelRegistry.shared where all || !m.hidden {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download, or 'bilingual' for the full bilingual set.")
        var id: String

        func run() throws {
            let models: [TranscriptionModel]
            if id == "bilingual" || id == "bilingual-nb-en" {
                do {
                    models = try BilingualConfiguration().models
                } catch {
                    print("\(error)")
                    throw ExitCode(1)
                }
            } else if let m = ModelRegistry.find(id) {
                models = [m]
            } else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do {
                    for m in models {
                        try await WhisperKitTranscriber(model: m).warmUp()
                    }
                } catch {
                    capturedError = error
                }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }

    struct Migrate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move the model cache out of iCloud-synced ~/Documents.",
            discussion: """
                Older versions downloaded models to ~/Documents/huggingface, \
                WhisperKit's default. With iCloud "Desktop & Documents Folders" \
                sync on, that uploads ~1 GB to iCloud and lets iCloud evict the \
                weights — which breaks bilingual warm-up with "Resource deadlock \
                avoided". This copies the cache to ~/Library/Application Support/\
                parrot/models, verifies every file, and only then removes the old \
                copy. Nothing is downloaded again.
                """
        )

        @Flag(name: .long, help: "Report what would move, then stop.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Leave the old copy in ~/Documents after a verified copy.")
        var keepOld: Bool = false

        func run() throws {
            let plan = CacheMigration.plan()
            guard !plan.isEmpty else {
                print("nothing to migrate — no cache at \(plan.source.path)")
                print("models are cached at \(plan.destination.appendingPathComponent("models").path)")
                return
            }
            print("from: \(plan.source.path)")
            print("  to: \(plan.destination.path)")
            print("      \(plan.items.count) files · \(CacheMigration.formatBytes(plan.totalBytes))")
            if plan.evictedCount > 0 {
                print("      \(plan.evictedCount) evicted by iCloud — those are downloaded first, which is the slow part")
            }
            if dryRun {
                print("(dry run — nothing moved)")
                return
            }
            do {
                try CacheMigration.run(plan, keepOld: keepOld)
            } catch let failure as CacheMigration.Failure {
                print("\(failure.description)")
                throw ExitCode(1)
            }
            print("✓ migrated to \(plan.destination.appendingPathComponent("models").path)")
            if keepOld {
                print("  old copy left at \(plan.source.path) — it is still synced to iCloud until you remove it")
            } else {
                print("  removed \(plan.source.path)")
            }
        }
    }
}

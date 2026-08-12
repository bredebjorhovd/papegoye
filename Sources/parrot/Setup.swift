import ApplicationServices
import ArgumentParser
import AVFoundation
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        print("parrot setup")
        print("============")
        print()
        print("Parrot needs two permissions:")
        print("  1. Accessibility — to detect the Fn key globally and inject text at the cursor.")
        print("  2. Microphone — to record audio while you hold Fn.")
        print()
        let subject = AccessibilitySubjectResolver.resolve()
        switch subject {
        case .hostApplication(let name, _):
            print("Both attach to \(name) — the app that launched parrot — not to parrot itself.")
        case .ownBinary(let path):
            print("No GUI app owns this session, so both attach to \(subject.displayName) itself:")
            print("  \(subject.grantPath ?? path)")
        }
        print()

        try waitForAccessibility(subject: subject)
        print()
        try waitForMicrophone()
        print()
        print("✓ all set. Run `parrot` to start the daemon.")
    }

    /// The prompt is a best case, not a guarantee: macOS shows it once per app,
    /// and not at all in a remote session. So ask, wait briefly, and if trust
    /// doesn't arrive fall through to a deep link that names the app the user
    /// has to toggle — then keep polling so a flipped switch finishes setup
    /// without a re-run (gh#31).
    private func waitForAccessibility(subject: AccessibilitySubject) throws {
        let store = AccessibilityStore.shared

        if AccessibilityTrust.isTrusted() {
            print("✓ accessibility already granted")
            store.noteGranted(subject: subject)
            return
        }

        let session = SessionKind.detect()
        let binary = BinaryIdentity.current()
        if case .ask = AccessibilityPrompting.decide(
            record: store.load(),
            binary: binary,
            session: session
        ) {
            print("→ asking macOS for accessibility access...")
            AccessibilityTrust.requestPrompt()
            store.notePrompted(binary: binary)
            if AccessibilityTrust.waitForTrust(seconds: AccessibilityTrust.promptGrace) {
                print("✓ accessibility granted")
                store.noteGranted(subject: subject)
                return
            }
            print()
        }

        let diagnosis = AccessibilityDiagnosis.classify(
            trusted: false,
            record: store.load(),
            binary: binary,
            session: session
        )
        for line in AccessibilityGuidance.instructions(for: diagnosis, subject: subject) {
            print(line)
        }

        if case .cannotPrompt = diagnosis {
            // Nothing to wait for: there is no local desktop to grant from.
            print()
            print("  then re-run `parrot setup` from the machine's own desktop.")
            throw ExitCode(1)
        }

        print()
        print("  opening \(AccessibilityGuidance.settingsPath)...")
        SystemSettings.open(pane: AccessibilityGuidance.settingsPane)
        let waitMinutes = Int(AccessibilityTrust.settingsGrace / 60)
        print("  waiting for the toggle (up to \(waitMinutes) min) — setup continues by itself. ^C to stop.")

        let granted = AccessibilityTrust.waitForTrust(
            seconds: AccessibilityTrust.settingsGrace,
            onPoll: { attempt in
                // A dot every 15s: enough to show it's alive, quiet enough to read.
                let every = Int(15 / AccessibilityTrust.pollInterval)
                if attempt > 0, attempt % every == 0 {
                    FileHandle.standardOutput.write(Data(".".utf8))
                }
            }
        )
        print()
        guard granted else {
            print("✗ still not granted after \(waitMinutes) min.")
            print("  flip the toggle, then re-run `parrot setup`.")
            throw ExitCode(1)
        }
        print("✓ accessibility granted")
        store.noteGranted(subject: subject)
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS won't re-prompt once denied.")
            print("  opening Settings → Privacy & Security → Microphone...")
            SystemSettings.open(pane: "Privacy_Microphone")
            print("  enable your terminal, then re-run `parrot setup`.")
            throw ExitCode(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw ExitCode(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }
}

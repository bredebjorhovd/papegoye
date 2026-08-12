import AVFoundation
import AppKit
import ApplicationServices
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
    /// Shown in place of the bare "ok" when a passing check still has something
    /// worth saying — which mic we picked, say.
    var detail: String? = nil
}

enum DoctorReport {
    /// `models` — the active configuration's model set (three in bilingual
    /// mode). Missing downloads are a warning, not a failure: warmup will
    /// download them, but on a slow link you'd rather know up front.
    /// `includeAgent` is off for `run`'s own startup checks: a foreground
    /// `parrot run` is a perfectly good reason for the LaunchAgent not to be
    /// running, and shouldn't be blocked by it.
    static func run(
        models: [TranscriptionModel] = [],
        inputPreference: InputDevicePolicy.Preference = .auto,
        includeAgent: Bool = false
    ) -> [Check] {
        var checks = [
            checkMicrophone(),
            checkInputDevice(AudioDevices.resolve(preference: inputPreference)),
            checkAccessibility(),
            checkCodeSignature(),
            checkFnKeyMapping(),
            checkModelCacheLocation(),
        ]
        if includeAgent, let agent = checkLaunchAgent() {
            checks.append(agent)
        }
        for m in models {
            checks.append(checkModelDownloaded(m))
        }
        return checks
    }

    /// A cache inside an iCloud-synced folder is both a quiet ~1 GB upload and
    /// the cause of the `EDEADLK` bilingual warm-up failure (gh#34), so say so
    /// even though nothing is broken yet on this machine.
    static func checkModelCacheLocation() -> Check {
        let name = "model cache"
        let legacy = ModelCache.documentsBase
        guard ModelCache.directoryNonEmpty(legacy.path) else {
            return Check(
                name: name,
                status: .ok,
                remediation: nil,
                detail: ModelCache.applicationSupportBase.appendingPathComponent("models").path
            )
        }
        guard ModelCache.isInSyncedFolder(legacy) else {
            return Check(name: name, status: .ok, remediation: nil, detail: legacy.path)
        }
        let evicted = ModelCache.evictedFileCount(under: legacy)
        let evictionNote = evicted > 0
            ? " — iCloud has already evicted \(evicted) file\(evicted == 1 ? "" : "s"), which breaks bilingual warm-up"
            : ""
        return Check(
            name: name,
            status: .warn("in an iCloud-synced folder: \(legacy.path)\(evictionNote)"),
            remediation: "parrot models migrate — moves it to \(ModelCache.applicationSupportBase.appendingPathComponent("models").path)"
        )
    }

    /// How the running binary is signed, which is what TCC keys its grants to.
    ///
    /// Nothing is broken when it is unsigned — that is how the released tarball
    /// ships — but it is the whole difference between a permission you grant
    /// once and one you re-grant after every upgrade, and it is otherwise
    /// invisible until the grant goes missing (gh#37). Only an expired
    /// certificate is a warning: the next build after that signs under an
    /// identity macOS has never seen.
    static func checkCodeSignature(
        _ signature: CodeSignature? = CodeSignature.current(),
        now: Date = Date()
    ) -> Check {
        let name = "code signature"
        let buildSigned =
            "`make install` builds a signed Papegøye.app, whose grant survives a rebuild"

        guard let signature else {
            return Check(
                name: name,
                status: .ok,
                remediation: buildSigned,
                detail: "unsigned — macOS drops the Accessibility grant whenever the binary changes"
            )
        }
        guard !signature.isAdHoc else {
            return Check(
                name: name,
                status: .ok,
                remediation: buildSigned,
                detail: "ad-hoc signed — the identity changes on every rebuild"
            )
        }

        var detail = signature.identifier
        if let authority = signature.authority {
            detail += " · \(authority)"
        }
        guard let expiry = signature.expiry else {
            return Check(name: name, status: .ok, remediation: nil, detail: detail)
        }
        if expiry < now {
            return Check(
                name: name,
                status: .warn("\(detail) — the certificate expired \(day(expiry))"),
                remediation: "renew it (Xcode → Settings → Accounts → Manage Certificates), "
                    + "rebuild, then re-grant Accessibility once"
            )
        }
        return Check(
            name: name,
            status: .ok,
            remediation: nil,
            detail: "\(detail) · expires \(day(expiry))"
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// nil when there is no LaunchAgent installed — most people run parrot from
    /// a terminal, and a row about something they never installed is noise.
    static func checkLaunchAgent(store: AccessibilityStore = .shared) -> Check? {
        guard LaunchAgentInspector.isInstalled() else { return nil }
        let subject = AccessibilitySubjectResolver.resolve()
        let diagnosis = AccessibilityDiagnosis.classify(
            trusted: AccessibilityTrust.isTrusted(),
            record: store.load(),
            binary: BinaryIdentity.current(),
            session: SessionKind.detect()
        )
        return check(
            forAgent: LaunchAgentInspector.state(),
            accessibility: diagnosis,
            subject: subject
        )
    }

    /// Pure mapping from launchd's view of the agent to a reported check.
    ///
    /// The case worth naming out loud is an agent that isn't running while the
    /// Accessibility grant is missing: before gh#35 that was a restart loop
    /// throwing a dialog every few seconds, and after it a daemon that has
    /// stopped on purpose. Either way nothing about it is self-explanatory.
    static func check(
        forAgent state: LaunchAgentState?,
        accessibility: AccessibilityDiagnosis,
        subject: AccessibilitySubject
    ) -> Check {
        let name = "launch agent"
        guard let state else {
            return Check(
                name: name,
                status: .warn("installed but not loaded"),
                remediation: "re-run `parrot install --launch-at-login` to load it"
            )
        }
        if let pid = state.pid {
            return Check(name: name, status: .ok, remediation: nil, detail: "running (pid \(pid))")
        }

        let permissionRemedy = AccessibilityGuidance.remediation(for: accessibility, subject: subject)
        let reload = "then reload it: launchctl kickstart -k gui/$(id -u)/\(Install.label)"

        if accessibility != .granted {
            let exited = state.lastExitStatus ?? 0
            let status: CheckStatus = exited == 0
                ? .fail("not running — it stops at startup because accessibility isn't granted")
                : .fail("not running — it exits \(exited) at startup and launchd keeps restarting it")
            return Check(
                name: name,
                status: status,
                remediation: [permissionRemedy, reload].compactMap { $0 }.joined(separator: "; ")
            )
        }

        if let exited = state.lastExitStatus, exited != 0 {
            return Check(
                name: name,
                status: .fail("not running — last exit \(exited)"),
                remediation: "see /tmp/parrot.err.log for why; \(reload)"
            )
        }
        return Check(
            name: name,
            status: .warn("installed but not running"),
            remediation: "see /tmp/parrot.err.log; \(reload)"
        )
    }

    /// WhisperKit (via swift-transformers' HubApi) caches models at
    /// <base>/models/<repo>/<variant>, where the base comes from `ModelCache`.
    /// A model with an explicit `modelFolder` is checked at that path instead.
    static func checkModelDownloaded(_ model: TranscriptionModel) -> Check {
        let name = "model \(model.id)"
        if let folder = model.modelFolder {
            if directoryNonEmpty(folder) {
                return Check(name: name, status: .ok, remediation: nil)
            }
            return Check(
                name: name,
                status: .fail("local model folder missing: \(folder)"),
                remediation: "check the path, or unset it to download from HF instead"
            )
        }
        guard let variant = model.whisperKitID else {
            return Check(name: name, status: .fail("no engine id"), remediation: nil)
        }
        let cached = ModelCache.cachedVariantDirectory(
            base: ModelCache.base(for: model),
            repo: model.repoID,
            variant: variant
        )
        if cached != nil {
            return Check(name: name, status: .ok, remediation: nil)
        }
        return Check(
            name: name,
            status: .warn("not downloaded — will download on first run"),
            remediation: "pre-fetch with `parrot models download \(model.id)`"
        )
    }

    private static func directoryNonEmpty(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return !contents.isEmpty
    }

    /// Report which microphone recording will actually use, and say so even
    /// when everything is fine — a policy that silently moves off the device
    /// the user picked in System Settings has to be visible somewhere (gh#30).
    static func checkInputDevice(_ selection: InputSelection) -> Check {
        let name = "input device"
        switch selection.reason {
        case .noMatch(let requested):
            let available = AudioDevices.inputDevices().map { $0.name }
            return Check(
                name: name,
                status: .fail(selection.description),
                remediation: available.isEmpty
                    ? "no input devices found at all — is \"\(requested)\" connected?"
                    : "available: \(available.joined(separator: ", "))"
            )
        case .noDevices:
            return Check(
                name: name,
                status: .warn("couldn't enumerate input devices"),
                remediation: "recording will fall back to the system default"
            )
        case .bluetoothUnavoidable:
            return Check(
                name: name,
                status: .warn(selection.description),
                remediation: "connect any other microphone to avoid the HFP downgrade"
            )
        case .explicit, .systemDefaultRequested, .systemDefault, .avoidedBluetooth:
            return Check(
                name: name,
                status: .ok,
                remediation: nil,
                detail: selection.description
            )
        }
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "run parrot and hold Fn once; macOS will prompt"
            )
        case .denied, .restricted:
            // The mic grant attaches to the same app the AX grant does.
            let subject = AccessibilitySubjectResolver.resolve().displayName
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for \(subject)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// "Not granted" and "not grantable from here" need different actions from
    /// the user, and a grant lost to a binary upgrade needs a third (gh#31), so
    /// report the diagnosis rather than the bare AX boolean.
    static func checkAccessibility(store: AccessibilityStore = .shared) -> Check {
        let subject = AccessibilitySubjectResolver.resolve()
        let trusted = AccessibilityTrust.isTrusted()
        if trusted {
            // Remember what was granted while we can see it — that record is
            // the only way a later run can tell an upgrade-revoked grant from
            // one that was never given.
            store.noteGranted(subject: subject)
        }
        let diagnosis = AccessibilityDiagnosis.classify(
            trusted: trusted,
            record: store.load(),
            binary: BinaryIdentity.current(),
            session: SessionKind.detect()
        )
        return check(for: diagnosis, subject: subject)
    }

    /// Pure mapping from diagnosis to reported check.
    static func check(
        for diagnosis: AccessibilityDiagnosis,
        subject: AccessibilitySubject
    ) -> Check {
        let remediation = AccessibilityGuidance.remediation(for: diagnosis, subject: subject)
        if case .granted = diagnosis {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        return Check(
            name: "accessibility",
            status: .fail(AccessibilityGuidance.summary(for: diagnosis)),
            remediation: remediation
        )
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        guard let raw, let value = Int(raw) else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Change Input Source"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 2:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Show Emoji & Symbols"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        case 3:
            return Check(
                name: "fn key mapping",
                status: .fail("set to Start Dictation"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

    private static func readDefault(domain: String, key: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", c.detail ?? "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    /// True only if every check passed cleanly (used by `parrot doctor` exit code).
    static func allClean(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .ok = $0.status { return true }
            return false
        }
    }
}

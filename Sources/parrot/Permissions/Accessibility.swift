import AppKit
import ApplicationServices
import Foundation

// Everything parrot knows about the Accessibility (AX) grant.
//
// The AX API can only answer one question — "is this process trusted?" — and
// answers `false` identically for "never asked", "asked and declined" and
// "cannot ask at all". Since macOS shows its prompt at most once per app,
// waiting for a prompt that will never come is the difference between setup
// working and setup looking broken (gh#31). So parrot keeps its own record of
// what it has already tried, and falls back to a System Settings deep link
// plus the name of the app the user actually has to toggle.

/// The entry in System Settings → Privacy & Security → Accessibility that
/// governs parrot.
///
/// TCC attributes the grant to the *responsible* process, not to the process
/// that calls the AX API: a terminal-launched parrot is governed by the
/// terminal (Terminal, iTerm, Ghostty…). Only when nothing GUI owns the
/// session — a LaunchAgent, an SSH login — is parrot itself the subject.
enum AccessibilitySubject: Codable, Equatable {
    case hostApplication(name: String, bundlePath: String?)
    case ownBinary(path: String)

    /// How to name the subject in a sentence.
    var displayName: String {
        switch self {
        case .hostApplication(let name, _):
            return name
        case .ownBinary(let path):
            // Installed as an app bundle, the row in the Accessibility list is
            // the app — under its own name, with its own icon — not "parrot".
            return AppBundle.enclosing(executable: path) == nil ? "parrot" : AppBundle.displayName
        }
    }

    /// What the user drags into the Accessibility list with +: the `.app` when
    /// parrot is installed as one, otherwise the binary itself.
    var grantPath: String? {
        switch self {
        case .hostApplication(_, let bundlePath):
            return bundlePath
        case .ownBinary(let path):
            return AppBundle.enclosing(executable: path) ?? path
        }
    }
}

/// A GUI application found while walking the process tree.
struct GUIApplication: Equatable {
    let name: String
    let bundlePath: String?
}

/// How parrot was reached, which decides whether a prompt can appear at all.
enum SessionKind: Equatable {
    case gui
    /// Remote login — the prompt would appear on a desktop nobody is looking at.
    case remote(host: String)
    /// Started by launchd. Nobody typed the command, so nobody is waiting to
    /// answer a modal dialog — and launchd restarts the job on failure, which
    /// turns one prompt into a prompt every few seconds (gh#35).
    case launchAgent

    /// SSH sets at least one of these on every login; `SSH_CONNECTION` carries
    /// "<client ip> <client port> <server ip> <server port>".
    static func detect(
        environment: [String: String],
        parentPID: pid_t = getppid(),
        hasTerminal: Bool = isatty(STDERR_FILENO) == 1
    ) -> SessionKind {
        if isUnderLaunchd(environment: environment, parentPID: parentPID, hasTerminal: hasTerminal) {
            return .launchAgent
        }
        if let connection = environment["SSH_CONNECTION"], !connection.isEmpty {
            let client = connection.split(separator: " ").first.map(String.init)
            return .remote(host: client ?? "a remote host")
        }
        if let client = environment["SSH_CLIENT"], !client.isEmpty {
            let host = client.split(separator: " ").first.map(String.init)
            return .remote(host: host ?? "a remote host")
        }
        if let tty = environment["SSH_TTY"], !tty.isEmpty {
            return .remote(host: "a remote host")
        }
        return .gui
    }

    /// Three ways a launchd job can recognise itself, any one of which is
    /// enough:
    ///
    /// - the marker `parrot install` bakes into its own plist — exact, but only
    ///   present on agents this version installed;
    /// - `XPC_SERVICE_NAME`, which launchd sets to the job label (a plain shell
    ///   inherits "0" instead);
    /// - being a child of pid 1 with no terminal, which is what a bootstrapped
    ///   agent looks like from the inside when the first two are missing.
    ///
    /// The last one alone would also match a disowned background process, so it
    /// needs both halves: a backgrounded `parrot run` keeps its tty.
    static func isUnderLaunchd(
        environment: [String: String],
        parentPID: pid_t,
        hasTerminal: Bool
    ) -> Bool {
        if environment[Install.launchdMarkerKey] == "1" { return true }
        if let service = environment["XPC_SERVICE_NAME"], service.contains(Install.label) {
            return true
        }
        if isApplicationLaunch(environment: environment) { return false }
        return parentPID == 1 && !hasTerminal
    }

    /// Whether LaunchServices started this process — i.e. someone opened
    /// `Papegøye.app` (gh#37).
    ///
    /// From the inside that looks exactly like a LaunchAgent: parent pid 1, no
    /// terminal, and `XPC_SERVICE_NAME=0`. The difference is that LaunchServices
    /// stamps the bundle identifier of the app it is launching into the
    /// environment, and launchd exec'ing the same binary out of the bundle does
    /// not. It matters because there *is* a user in front of a double-clicked
    /// app, and they should get the permission dialog the daemon must never
    /// open.
    ///
    /// The launchd marker is checked before this, so an agent installed by
    /// `parrot install` stays recognised as an agent no matter what else is in
    /// its environment — the gh#35 prompt storm can't come back through here.
    static func isApplicationLaunch(environment: [String: String]) -> Bool {
        environment["__CFBundleIdentifier"] == AppBundle.identifier
    }

    static func detect() -> SessionKind {
        detect(environment: ProcessInfo.processInfo.environment)
    }
}

/// Path plus whatever identifies the binary to TCC.
///
/// Unsigned binaries are identified by path *and* contents, so a release
/// upgrade that overwrites the file silently invalidates an existing grant.
/// Size and modification date are enough to notice that happened.
///
/// A properly signed binary is identified by its signature instead, and that
/// is the whole point of shipping a signed `Papegøye.app` (gh#37): a rebuild
/// changes every byte and none of the identity, so parrot must not report a
/// grant as lost — or spend a fresh prompt — over a file that macOS considers
/// the same program.
struct BinaryIdentity: Codable, Equatable {
    let path: String
    let fingerprint: String

    static func of(path: String, fileManager: FileManager = .default) -> BinaryIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        if let stable = CodeSignature.of(path: path)?.stableFingerprint {
            return BinaryIdentity(path: path, fingerprint: stable)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return BinaryIdentity(
            path: path,
            fingerprint: String(format: "%lld-%.0f", size, modified)
        )
    }

    static func current() -> BinaryIdentity? {
        guard let path = ExecutablePath.current() else { return nil }
        return of(path: path)
    }
}

/// Absolute, symlink-resolved path of the running executable, regardless of how
/// it was invoked (PATH lookup, symlink, explicit path).
enum ExecutablePath {
    static func current() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        var path = String(cString: buffer)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            path = String(cString: resolved)
        }
        return path
    }
}

/// Finds the app whose Accessibility toggle governs this process by walking up
/// the process tree to the nearest GUI application.
enum AccessibilitySubjectResolver {
    /// parrot → zsh → login → Terminal is three hops; the cap only exists so a
    /// pid cycle can't spin forever.
    static let maxDepth = 16

    static func resolve(
        from pid: pid_t,
        ownBinaryPath: String,
        parent: (pid_t) -> pid_t?,
        application: (pid_t) -> GUIApplication?
    ) -> AccessibilitySubject {
        var current = pid
        var seen: Set<pid_t> = []
        for _ in 0..<maxDepth {
            if let app = application(current) {
                return .hostApplication(name: app.name, bundlePath: app.bundlePath)
            }
            seen.insert(current)
            guard let next = parent(current), next > 1, !seen.contains(next) else { break }
            current = next
        }
        return .ownBinary(path: ownBinaryPath)
    }

    static func resolve() -> AccessibilitySubject {
        // Start at the parent: parrot's own pid resolves to an
        // NSRunningApplication too, and it is never the AX subject when a
        // terminal launched it.
        resolve(
            from: getppid(),
            ownBinaryPath: ExecutablePath.current() ?? "the parrot binary",
            parent: parentPID(of:),
            application: guiApplication(for:)
        )
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// A bundled, dock-visible app — i.e. something that can appear in the
    /// Accessibility list. Plain processes (shells, `login`) return nil.
    static func guiApplication(for pid: pid_t) -> GUIApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier,
              app.activationPolicy == .regular
        else {
            return nil
        }
        let name = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? bundleID
        return GUIApplication(name: name, bundlePath: app.bundleURL?.path)
    }
}

/// What parrot remembers about the grant between runs. Written best-effort:
/// losing it costs nothing but a less specific message next time.
struct AccessibilityRecord: Codable, Equatable {
    /// True once parrot has asked macOS to show the prompt. macOS won't show it
    /// twice, so a second `false` from the AX API means "go to Settings", not
    /// "wait for a dialog".
    var prompted: Bool = false
    /// Which binary the prompt was spent on. TCC keys an unsigned binary by
    /// path and contents, so a replaced binary gets a fresh prompt — and this
    /// is how parrot knows the difference between that and asking twice for the
    /// same one.
    var promptedBinary: BinaryIdentity?
    var grantedSubject: AccessibilitySubject?
    var grantedBinary: BinaryIdentity?

    /// True when macOS's one-per-identity prompt has already been spent on this
    /// exact binary — i.e. asking again would open a dialog for nothing, or
    /// (worse, under launchd) once per restart.
    ///
    /// A record written before parrot tracked the identity has `prompted` but
    /// no `promptedBinary`; so does a run that couldn't stat its own binary.
    /// Both resolve to "already asked", because too few prompts costs a line of
    /// text and too many is gh#35.
    func hasPrompted(for binary: BinaryIdentity?) -> Bool {
        guard prompted else { return false }
        guard let promptedBinary, let binary else { return true }
        return promptedBinary == binary
    }
}

struct AccessibilityStore {
    let directory: URL

    static let shared = AccessibilityStore(directory: defaultDirectory())

    /// `PARROT_STATE_DIR` exists so tests (and anyone debugging) can point the
    /// record somewhere disposable.
    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["PARROT_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/parrot", isDirectory: true)
    }

    var fileURL: URL {
        directory.appendingPathComponent("accessibility.json")
    }

    func load() -> AccessibilityRecord {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(AccessibilityRecord.self, from: data)
        else {
            return AccessibilityRecord()
        }
        return record
    }

    func save(_ record: AccessibilityRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records that the prompt has been spent, against the binary that spent
    /// it. Written *before* waiting for an answer: a user who ignores the
    /// dialog must not be asked again either.
    func notePrompted(binary: BinaryIdentity? = BinaryIdentity.current()) {
        var record = load()
        guard !record.hasPrompted(for: binary) else { return }
        record.prompted = true
        record.promptedBinary = binary
        save(record)
    }

    /// Called whenever trust is observed, so a later run can tell "never
    /// granted" from "granted, then the binary was replaced".
    func noteGranted(subject: AccessibilitySubject, binary: BinaryIdentity? = BinaryIdentity.current()) {
        let record = load()
        var updated = record
        updated.grantedSubject = subject
        updated.grantedBinary = binary
        guard updated != record else { return }
        save(updated)
    }
}

/// Why the AX API is returning `false`, as far as parrot can tell.
enum AccessibilityDiagnosis: Equatable {
    case granted
    /// No prompt shown yet — asking should produce one.
    case notYetPrompted
    /// parrot already asked. macOS shows that prompt once, so asking again is
    /// silent: only System Settings can fix it now.
    case promptAlreadySpent
    /// The prompt cannot appear in this kind of session at all.
    case cannotPrompt(reason: String)
    /// parrot had the grant, and the binary it was granted to has since been
    /// replaced — the usual outcome of upgrading an unsigned release in place.
    case revokedAfterUpgrade(previous: BinaryIdentity)

    static func classify(
        trusted: Bool,
        record: AccessibilityRecord,
        binary: BinaryIdentity?,
        session: SessionKind
    ) -> AccessibilityDiagnosis {
        if trusted { return .granted }
        switch session {
        case .remote(let host):
            return .cannotPrompt(
                reason: "this is an SSH session from \(host); macOS only shows the prompt on the local desktop"
            )
        case .launchAgent:
            return .cannotPrompt(
                reason: "launchd started parrot, and a background agent has no interactive session to show a dialog in"
            )
        case .gui:
            break
        }
        // Only meaningful when the grant was on parrot's own binary: a grant on
        // the terminal survives parrot upgrades untouched.
        if case .ownBinary = record.grantedSubject,
           let previous = record.grantedBinary,
           let binary,
           binary != previous
        {
            return .revokedAfterUpgrade(previous: previous)
        }
        if record.hasPrompted(for: binary) { return .promptAlreadySpent }
        return .notYetPrompted
    }
}

/// The single decision about whether parrot may put a modal dialog on screen.
///
/// Every `AXIsProcessTrustedWithOptions([prompt: true])` can open one, and the
/// daemon used to make that call once per start. Under
/// `KeepAlive {SuccessfulExit: false}` a failing start is followed by another
/// start, so one missing grant became a dialog every few seconds (gh#35). The
/// decision therefore reads state that outlives the process, and is made in one
/// place that both `run` and `setup` go through.
enum AccessibilityPrompting {
    enum Decision: Equatable {
        /// Ask macOS to show the prompt, then write the record.
        case ask
        /// Check trust silently and say why there will be no dialog.
        case doNotAsk(Reason)
    }

    enum Reason: Equatable {
        case underLaunchd
        case remote(host: String)
        case alreadyAskedForThisBinary
    }

    static func decide(
        record: AccessibilityRecord,
        binary: BinaryIdentity?,
        session: SessionKind
    ) -> Decision {
        switch session {
        case .launchAgent:
            return .doNotAsk(.underLaunchd)
        case .remote(let host):
            return .doNotAsk(.remote(host: host))
        case .gui:
            break
        }
        if record.hasPrompted(for: binary) { return .doNotAsk(.alreadyAskedForThisBinary) }
        return .ask
    }
}

/// The words `setup` and `doctor` put on screen. Kept pure so the wording is
/// testable — it is the whole deliverable of gh#31.
enum AccessibilityGuidance {
    static let settingsPane = "Privacy_Accessibility"
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)"
    static let settingsPath = "System Settings → Privacy & Security → Accessibility"

    /// `doctor`'s status text.
    static func summary(for diagnosis: AccessibilityDiagnosis) -> String {
        switch diagnosis {
        case .granted:
            return "granted"
        case .notYetPrompted:
            return "not granted"
        case .promptAlreadySpent:
            return "not granted — macOS won't show the prompt again"
        case .cannotPrompt:
            return "not granted — macOS can't show the prompt in this session"
        case .revokedAfterUpgrade:
            return "grant lost when the parrot binary was replaced"
        }
    }

    /// `doctor`'s one-line remediation.
    static func remediation(
        for diagnosis: AccessibilityDiagnosis,
        subject: AccessibilitySubject
    ) -> String? {
        switch diagnosis {
        case .granted:
            return nil
        case .notYetPrompted:
            return "run `parrot setup` — macOS will ask on behalf of \(subject.displayName)"
        case .promptAlreadySpent:
            return "\(settingsPath) → \(enableClause(subject)); `parrot setup` opens it for you"
        case .cannotPrompt(let reason):
            return "\(reason). \(settingsPath) → \(enableClause(subject))"
        case .revokedAfterUpgrade(let previous):
            return "unsigned binaries are keyed by path and contents, so the new binary isn't the one you granted: "
                + "\(settingsPath) → remove the old parrot entry with −, then re-add \(previous.path)"
        }
    }

    /// `setup`'s instructions, printed after the prompt failed to show up.
    static func instructions(
        for diagnosis: AccessibilityDiagnosis,
        subject: AccessibilitySubject
    ) -> [String] {
        var lines: [String] = []
        switch diagnosis {
        case .granted:
            return []
        case .notYetPrompted, .promptAlreadySpent:
            lines.append("  no prompt appeared — macOS offers it only once per app.")
        case .cannotPrompt(let reason):
            lines.append("  no prompt is possible here: \(reason).")
        case .revokedAfterUpgrade(let previous):
            lines.append("  parrot had this grant before, but the binary at \(previous.path) has changed since.")
            lines.append("  macOS identifies unsigned binaries by path and contents, so the grant no longer applies.")
        }

        lines.append("")
        switch subject {
        case .hostApplication(let name, let bundlePath):
            lines.append("  \(name) is the app that needs Accessibility access — the grant attaches to")
            lines.append("  your terminal, not to parrot itself.")
            if let bundlePath {
                lines.append("    \(bundlePath)")
            }
            if case .revokedAfterUpgrade = diagnosis {
                lines.append("  1. Remove \(name) from the list with −, then re-add it with +.")
            } else {
                lines.append("  1. Toggle \(name) on in the Accessibility list.")
            }
        case .ownBinary(let path):
            // Bundled, the entry is Papegøye.app; unbundled, it is the binary.
            let target = subject.grantPath ?? path
            lines.append("  No GUI app owns this session, so \(subject.displayName) itself is the entry")
            lines.append("  that needs Accessibility access:")
            lines.append("    \(target)")
            if case .revokedAfterUpgrade = diagnosis {
                lines.append("  1. Remove the old parrot entry with −, then add \(target) with +.")
            } else {
                lines.append("  1. Add \(target) to the Accessibility list with +.")
            }
            lines.append("     (inside tmux or screen, grant that binary instead — it owns the session)")
        }
        lines.append("  2. \(settingsPath)")
        return lines
    }

    /// What `parrot run` writes to stderr when it can't tap the keyboard.
    ///
    /// Under launchd this is the whole user-visible artefact of the failure —
    /// /tmp/parrot.err.log is the only place it lands — so it has to say what
    /// is wrong, what to do, and why parrot is not going to try again.
    static func daemonFailure(
        for diagnosis: AccessibilityDiagnosis,
        subject: AccessibilitySubject,
        session: SessionKind
    ) -> [String] {
        var lines = ["accessibility not granted — parrot can't watch the Fn key or type at the cursor."]
        lines.append("  \(summary(for: diagnosis))")
        if let remediation = remediation(for: diagnosis, subject: subject) {
            lines.append("  → \(remediation)")
        }
        if session == .launchAgent {
            // Exiting 0 is the mechanism; saying so is the point. Anyone
            // reading this log is looking at a daemon that quietly isn't there.
            lines.append("  exiting cleanly so launchd doesn't restart the loop — a permission")
            lines.append("  can't be granted by trying again, and each retry reloads the models.")
            lines.append("  once it's granted: launchctl kickstart -k gui/$(id -u)/\(Install.label)")
        } else {
            lines.append("  run `parrot setup` to sort it out.")
        }
        return lines
    }

    /// A missing grant is not transient, so under launchd parrot exits 0: with
    /// `KeepAlive {SuccessfulExit: false}` that is the exit status that means
    /// "leave me alone". In a terminal the failure is still a failure.
    static func daemonExitCode(for session: SessionKind) -> Int32 {
        session == .launchAgent ? 0 : 1
    }

    private static func enableClause(_ subject: AccessibilitySubject) -> String {
        switch subject {
        case .hostApplication(let name, _):
            return "enable \(name) (your terminal, not parrot)"
        case .ownBinary(let path):
            return "add \(subject.grantPath ?? path)"
        }
    }
}

/// The live side of the AX check: trust, the one-shot prompt, and polling.
enum AccessibilityTrust {
    static let pollInterval: TimeInterval = 0.5
    /// How long to give the prompt before concluding it will never appear.
    static let promptGrace: TimeInterval = 4
    /// How long to keep watching after sending the user to System Settings.
    static let settingsGrace: TimeInterval = 180

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Ask macOS to show the prompt. Silent no-op if it has been shown before.
    static func requestPrompt() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    static func polls(for duration: TimeInterval, interval: TimeInterval = pollInterval) -> Int {
        max(1, Int((duration / interval).rounded()))
    }

    /// Poll until trusted or out of attempts. Injectable so the polling logic is
    /// testable without a real TCC grant or a real clock.
    static func waitForTrust(
        polls: Int,
        interval: TimeInterval = pollInterval,
        isTrusted: () -> Bool = isTrusted,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onPoll: (Int) -> Void = { _ in }
    ) -> Bool {
        for attempt in 0..<max(0, polls) {
            if isTrusted() { return true }
            onPoll(attempt)
            sleep(interval)
        }
        return isTrusted()
    }

    static func waitForTrust(seconds: TimeInterval, onPoll: (Int) -> Void = { _ in }) -> Bool {
        waitForTrust(polls: polls(for: seconds), onPoll: onPoll)
    }
}

enum SystemSettings {
    /// Best-effort: on a remote session `open` has no desktop to talk to, which
    /// is exactly why callers also print the path in words.
    static func open(pane: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["x-apple.systempreferences:com.apple.preference.security?\(pane)"]
        try? task.run()
    }
}

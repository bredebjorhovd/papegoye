import Foundation
import XCTest
@testable import parrot

/// gh#31: when the accessibility prompt never appears, everything the user has
/// to act on comes out of these four pieces — which app owns the grant, whether
/// a prompt is even possible, what state the grant is in, and the words printed
/// about it. None of them touch TCC, so they are the part worth pinning.
final class AccessibilityTests: XCTestCase {
    private let ghostty = AccessibilitySubject.hostApplication(
        name: "Ghostty",
        bundlePath: "/Applications/Ghostty.app"
    )
    private let ownBinary = AccessibilitySubject.ownBinary(path: "/usr/local/bin/parrot")

    // MARK: - Which app the user has to toggle

    /// parrot → zsh → login → Ghostty: the terminal is the AX subject, not the
    /// shell in between and not parrot.
    func testResolvesTheGUIAncestorThroughTheShellChain() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 200]
        let subject = AccessibilitySubjectResolver.resolve(
            from: 500,
            ownBinaryPath: "/usr/local/bin/parrot",
            parent: { parents[$0] },
            application: { $0 == 200 ? GUIApplication(name: "Ghostty", bundlePath: "/Applications/Ghostty.app") : nil }
        )
        XCTAssertEqual(subject, ghostty)
    }

    /// A LaunchAgent or ssh login has no GUI ancestor, and then parrot's own
    /// binary is the entry in the list.
    func testFallsBackToOwnBinaryWhenNoGUIAncestorExists() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 1]
        let subject = AccessibilitySubjectResolver.resolve(
            from: 500,
            ownBinaryPath: "/usr/local/bin/parrot",
            parent: { parents[$0] },
            application: { _ in nil }
        )
        XCTAssertEqual(subject, ownBinary)
    }

    func testResolutionSurvivesAPIDCycle() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 500]
        let subject = AccessibilitySubjectResolver.resolve(
            from: 500,
            ownBinaryPath: "/usr/local/bin/parrot",
            parent: { parents[$0] },
            application: { _ in nil }
        )
        XCTAssertEqual(subject, ownBinary)
    }

    func testResolutionStopsAtTheDepthCap() {
        // Every pid has a parent and none is a GUI app: the walk must terminate.
        let subject = AccessibilitySubjectResolver.resolve(
            from: 1_000,
            ownBinaryPath: "/usr/local/bin/parrot",
            parent: { $0 + 1 },
            application: { _ in nil }
        )
        XCTAssertEqual(subject, ownBinary)
    }

    /// The live resolver has to survive being asked on a real machine — a test
    /// process has no GUI ancestor, so it must land on the binary, not crash or
    /// claim the test runner is a terminal.
    func testLiveResolutionReturnsSomethingUsable() {
        switch AccessibilitySubjectResolver.resolve() {
        case .hostApplication(let name, _):
            XCTAssertFalse(name.isEmpty)
        case .ownBinary(let path):
            XCTAssertFalse(path.isEmpty)
        }
    }

    // MARK: - Whether a prompt is possible at all

    func testSSHSessionsCannotShowAPrompt() {
        XCTAssertEqual(
            SessionKind.detect(environment: ["SSH_CONNECTION": "10.0.0.2 51000 10.0.0.9 22"]),
            .remote(host: "10.0.0.2")
        )
        XCTAssertEqual(
            SessionKind.detect(environment: ["SSH_CLIENT": "10.0.0.2 51000 22"]),
            .remote(host: "10.0.0.2")
        )
        XCTAssertEqual(
            SessionKind.detect(environment: ["SSH_TTY": "/dev/ttys003"]),
            .remote(host: "a remote host")
        )
    }

    func testLocalSessionIsGUI() {
        XCTAssertEqual(SessionKind.detect(environment: ["TERM": "xterm-256color"]), .gui)
        XCTAssertEqual(SessionKind.detect(environment: ["SSH_CONNECTION": ""]), .gui)
    }

    // MARK: - Running under launchd (gh#35)

    private func detect(
        _ environment: [String: String],
        parentPID: pid_t = 4_242,
        hasTerminal: Bool = true
    ) -> SessionKind {
        SessionKind.detect(environment: environment, parentPID: parentPID, hasTerminal: hasTerminal)
    }

    func testTheMarkerInOurOwnPlistIsEnoughToRecogniseLaunchd() {
        XCTAssertEqual(detect([Install.launchdMarkerKey: "1"]), .launchAgent)
    }

    func testLaunchdIsRecognisedFromTheJobLabelItExports() {
        XCTAssertEqual(detect(["XPC_SERVICE_NAME": Install.label]), .launchAgent)
    }

    /// Agents installed before the marker existed have neither it nor, on some
    /// macOS versions, a useful XPC_SERVICE_NAME — but they are always a child
    /// of launchd with their output redirected to a log file.
    func testAnOlderAgentIsRecognisedByItsParentAndMissingTerminal() {
        XCTAssertEqual(detect([:], parentPID: 1, hasTerminal: false), .launchAgent)
    }

    func testATerminalSessionIsNeverMistakenForLaunchd() {
        // XPC_SERVICE_NAME is "0" in a normal login shell, and a pipeline
        // (`parrot run | tee`) has no tty while still being a terminal session.
        XCTAssertEqual(detect(["XPC_SERVICE_NAME": "0"]), .gui)
        XCTAssertEqual(detect([:], parentPID: 900, hasTerminal: false), .gui)
        XCTAssertEqual(detect([:], parentPID: 1, hasTerminal: true), .gui)
    }

    /// launchd wins over the SSH variables: an agent bootstrapped from an ssh
    /// session inherits neither an answerable dialog nor the ssh environment's
    /// meaning.
    func testLaunchdOutranksSSHDetection() {
        XCTAssertEqual(
            detect([
                Install.launchdMarkerKey: "1",
                "SSH_CONNECTION": "10.0.0.2 51000 10.0.0.9 22",
            ]),
            .launchAgent
        )
    }

    func testDaemonSessionCannotPrompt() {
        let diagnosis = classify(session: .launchAgent)
        guard case .cannotPrompt(let reason) = diagnosis else {
            return XCTFail("expected cannotPrompt, got \(diagnosis)")
        }
        XCTAssertTrue(reason.contains("launchd"))
    }

    // MARK: - Whether to open a dialog at all (gh#35)

    private func decide(
        record: AccessibilityRecord = AccessibilityRecord(),
        binary: BinaryIdentity? = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2"),
        session: SessionKind = .gui
    ) -> AccessibilityPrompting.Decision {
        AccessibilityPrompting.decide(record: record, binary: binary, session: session)
    }

    func testFirstRunInATerminalMayAsk() {
        XCTAssertEqual(decide(), .ask)
    }

    /// The bug: the daemon asked on every start, and launchd restarts it on
    /// every failure. Nothing about a background agent may open a dialog.
    func testADaemonNeverAsksEvenOnAVirginRecord() {
        XCTAssertEqual(decide(session: .launchAgent), .doNotAsk(.underLaunchd))
    }

    func testARemoteSessionNeverAsks() {
        XCTAssertEqual(
            decide(session: .remote(host: "10.0.0.2")),
            .doNotAsk(.remote(host: "10.0.0.2"))
        )
    }

    func testTheSecondStartOfTheSameBinaryDoesNotAsk() {
        let binary = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")
        let record = AccessibilityRecord(prompted: true, promptedBinary: binary)
        XCTAssertEqual(decide(record: record, binary: binary), .doNotAsk(.alreadyAskedForThisBinary))
    }

    /// A replaced binary is a new client to TCC, so its prompt is available
    /// again — once.
    func testAReplacedBinaryEarnsOneFreshPrompt() {
        let record = AccessibilityRecord(
            prompted: true,
            promptedBinary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        )
        XCTAssertEqual(
            decide(record: record, binary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")),
            .ask
        )
    }

    /// A record written before parrot tracked the identity, and a run that
    /// can't stat its own binary, both have to mean "don't ask": guessing wrong
    /// in the other direction is the prompt storm.
    func testAnUnattributedPromptCountsAsSpent() {
        XCTAssertEqual(
            decide(record: AccessibilityRecord(prompted: true)),
            .doNotAsk(.alreadyAskedForThisBinary)
        )
        let record = AccessibilityRecord(
            prompted: true,
            promptedBinary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        )
        XCTAssertEqual(decide(record: record, binary: nil), .doNotAsk(.alreadyAskedForThisBinary))
    }

    /// The regression in one test: seventeen restarts of the same binary, one
    /// dialog. The record is the only thing that survives between them, so the
    /// store has to be in the loop.
    func testARestartLoopProducesExactlyOnePrompt() throws {
        let store = try temporaryStore()
        let binary = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")
        var asked = 0
        for _ in 0..<17 {
            if case .ask = AccessibilityPrompting.decide(
                record: store.load(),
                binary: binary,
                session: .gui
            ) {
                asked += 1
                store.notePrompted(binary: binary)
            }
        }
        XCTAssertEqual(asked, 1)
    }

    func testARestartLoopUnderLaunchdPromptsNotAtAll() throws {
        let store = try temporaryStore()
        let binary = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")
        for _ in 0..<17 {
            XCTAssertEqual(
                AccessibilityPrompting.decide(record: store.load(), binary: binary, session: .launchAgent),
                .doNotAsk(.underLaunchd)
            )
        }
        XCTAssertFalse(store.load().prompted, "nothing was asked, so nothing was spent")
    }

    // MARK: - What the daemon says and how it exits (gh#35)

    /// A missing permission is not transient: with
    /// `KeepAlive {SuccessfulExit: false}`, exiting 0 is how the daemon tells
    /// launchd to stop trying.
    func testTheDaemonExitsZeroSoLaunchdLeavesItAlone() {
        XCTAssertEqual(AccessibilityGuidance.daemonExitCode(for: .launchAgent), 0)
        XCTAssertEqual(AccessibilityGuidance.daemonExitCode(for: .gui), 1)
        XCTAssertEqual(AccessibilityGuidance.daemonExitCode(for: .remote(host: "x")), 1)
    }

    func testDaemonFailureExplainsWhyItIsNotRetrying() {
        let lines = AccessibilityGuidance.daemonFailure(
            for: .cannotPrompt(reason: "launchd started parrot"),
            subject: ownBinary,
            session: .launchAgent
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("accessibility not granted"))
        XCTAssertTrue(lines.contains("/usr/local/bin/parrot"), "the entry to add has to be named")
        XCTAssertTrue(lines.contains("launchd doesn't restart"), "silence needs explaining")
        XCTAssertTrue(lines.contains("kickstart"), "and so does how to start it again afterwards")
    }

    func testDaemonFailureInATerminalPointsAtSetup() {
        let lines = AccessibilityGuidance.daemonFailure(
            for: .notYetPrompted,
            subject: ghostty,
            session: .gui
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("parrot setup"))
        XCTAssertFalse(lines.contains("kickstart"), "no agent is involved when a human ran it")
    }

    // MARK: - Diagnosis

    private func classify(
        trusted: Bool = false,
        record: AccessibilityRecord = AccessibilityRecord(),
        binary: BinaryIdentity? = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2"),
        session: SessionKind = .gui
    ) -> AccessibilityDiagnosis {
        AccessibilityDiagnosis.classify(
            trusted: trusted,
            record: record,
            binary: binary,
            session: session
        )
    }

    func testTrustShortCircuitsEverything() {
        XCTAssertEqual(
            classify(trusted: true, record: AccessibilityRecord(prompted: true), session: .remote(host: "x")),
            .granted
        )
    }

    func testNeverPromptedIsDistinctFromPromptSpent() {
        XCTAssertEqual(classify(), .notYetPrompted)
        XCTAssertEqual(
            classify(record: AccessibilityRecord(prompted: true)),
            .promptAlreadySpent,
            "macOS shows the prompt once; a second silent no-op is not 'wait for a dialog'"
        )
    }

    func testRemoteSessionOutranksThePromptedFlag() {
        let diagnosis = classify(record: AccessibilityRecord(prompted: false), session: .remote(host: "10.0.0.2"))
        guard case .cannotPrompt(let reason) = diagnosis else {
            return XCTFail("expected cannotPrompt, got \(diagnosis)")
        }
        XCTAssertTrue(reason.contains("10.0.0.2"))
    }

    /// The upgrade case: parrot had the grant on its own binary, and the file
    /// has since been replaced.
    func testReplacedBinaryIsReportedAsARevokedGrant() {
        let previous = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        let record = AccessibilityRecord(
            prompted: true,
            grantedSubject: ownBinary,
            grantedBinary: previous
        )
        XCTAssertEqual(
            classify(record: record, binary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")),
            .revokedAfterUpgrade(previous: previous)
        )
    }

    func testUnchangedBinaryIsNotBlamedForALostGrant() {
        let identity = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        let record = AccessibilityRecord(
            prompted: true,
            grantedSubject: ownBinary,
            grantedBinary: identity
        )
        XCTAssertEqual(classify(record: record, binary: identity), .promptAlreadySpent)
    }

    /// A grant on the terminal is untouched by a parrot upgrade, so an upgraded
    /// binary must not be blamed for it.
    func testUpgradeIsNotBlamedWhenTheGrantWasOnTheTerminal() {
        let record = AccessibilityRecord(
            prompted: true,
            grantedSubject: ghostty,
            grantedBinary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        )
        XCTAssertEqual(
            classify(record: record, binary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")),
            .promptAlreadySpent
        )
    }

    func testUnreadableBinaryIdentityFallsBackToThePromptedFlag() {
        let record = AccessibilityRecord(
            prompted: true,
            grantedSubject: ownBinary,
            grantedBinary: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        )
        XCTAssertEqual(classify(record: record, binary: nil), .promptAlreadySpent)
    }

    // MARK: - What the user is told

    func testSetupInstructionsNameTheTerminalAndTheSettingsPath() {
        let lines = AccessibilityGuidance.instructions(for: .promptAlreadySpent, subject: ghostty)
            .joined(separator: "\n")
        XCTAssertTrue(lines.contains("Ghostty"), "the app to toggle has to be named")
        XCTAssertTrue(lines.contains("/Applications/Ghostty.app"))
        XCTAssertTrue(lines.contains("not to parrot itself"), "granting parrot is the mistake people make")
        XCTAssertTrue(lines.contains(AccessibilityGuidance.settingsPath))
        XCTAssertTrue(lines.contains("no prompt appeared"))
    }

    func testSetupInstructionsForABinarySubjectPointAtThePath() {
        let lines = AccessibilityGuidance.instructions(for: .notYetPrompted, subject: ownBinary)
            .joined(separator: "\n")
        XCTAssertTrue(lines.contains("/usr/local/bin/parrot"))
        XCTAssertTrue(lines.contains("tmux"), "under a multiplexer the entry is that binary, not parrot")
    }

    func testCannotPromptInstructionsExplainWhy() {
        let lines = AccessibilityGuidance.instructions(
            for: .cannotPrompt(reason: "this is an SSH session from 10.0.0.2"),
            subject: ghostty
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("no prompt is possible here"))
        XCTAssertTrue(lines.contains("10.0.0.2"))
    }

    func testRevokedGrantInstructionsSayToRemoveAndReAdd() {
        let previous = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        let lines = AccessibilityGuidance.instructions(
            for: .revokedAfterUpgrade(previous: previous),
            subject: ownBinary
        ).joined(separator: "\n")
        XCTAssertTrue(lines.contains("has changed since"))
        XCTAssertTrue(lines.contains("Remove the old parrot entry with −"))
    }

    func testGrantedSubjectNeedsNoInstructions() {
        XCTAssertTrue(AccessibilityGuidance.instructions(for: .granted, subject: ghostty).isEmpty)
    }

    func testDeepLinkTargetsTheAccessibilityPane() {
        XCTAssertEqual(
            AccessibilityGuidance.settingsURL,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    // MARK: - doctor

    func testDoctorSeparatesNotGrantedFromCannotPrompt() {
        let notGranted = DoctorReport.check(for: .notYetPrompted, subject: ghostty)
        guard case .fail(let notGrantedMessage) = notGranted.status else {
            return XCTFail("expected a failure, got \(notGranted.status)")
        }
        XCTAssertEqual(notGrantedMessage, "not granted")
        XCTAssertEqual(
            notGranted.remediation,
            "run `parrot setup` — macOS will ask on behalf of Ghostty"
        )

        let cannotPrompt = DoctorReport.check(
            for: .cannotPrompt(reason: "this is an SSH session from 10.0.0.2"),
            subject: ghostty
        )
        guard case .fail(let cannotPromptMessage) = cannotPrompt.status else {
            return XCTFail("expected a failure, got \(cannotPrompt.status)")
        }
        XCTAssertNotEqual(
            cannotPromptMessage, notGrantedMessage,
            "the two states need different actions from the user, so they can't read the same"
        )
        XCTAssertTrue(cannotPromptMessage.contains("can't show the prompt"))
        XCTAssertTrue(cannotPrompt.remediation?.contains("10.0.0.2") ?? false)
    }

    func testDoctorReportsAPromptThatWillNeverComeAgain() {
        let check = DoctorReport.check(for: .promptAlreadySpent, subject: ghostty)
        guard case .fail(let message) = check.status else {
            return XCTFail("expected a failure, got \(check.status)")
        }
        XCTAssertTrue(message.contains("won't show the prompt again"))
        XCTAssertTrue(check.remediation?.contains("enable Ghostty") ?? false)
    }

    func testDoctorExplainsARevokedGrantAsAnUpgradeArtifact() {
        let check = DoctorReport.check(
            for: .revokedAfterUpgrade(previous: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")),
            subject: ownBinary
        )
        guard case .fail(let message) = check.status else {
            return XCTFail("expected a failure, got \(check.status)")
        }
        XCTAssertTrue(message.contains("binary was replaced"))
        XCTAssertTrue(check.remediation?.contains("path and contents") ?? false)
        XCTAssertTrue(check.remediation?.contains("/usr/local/bin/parrot") ?? false)
    }

    // MARK: - doctor on the LaunchAgent (gh#35)

    func testLaunchctlListIsParsedIntoRunningAndStoppedStates() {
        let output = """
            -\t0\tcom.apple.SafariHistoryServiceAgent
            4711\t0\tcom.digimata.parrot
            -\t1\tcom.example.other
            """
        XCTAssertEqual(
            LaunchAgentInspector.parse(list: output),
            LaunchAgentState(pid: 4_711, lastExitStatus: 0)
        )
        XCTAssertTrue(LaunchAgentInspector.parse(list: output)?.isRunning ?? false)

        let failing = "-\t1\tcom.digimata.parrot"
        XCTAssertEqual(
            LaunchAgentInspector.parse(list: failing),
            LaunchAgentState(pid: nil, lastExitStatus: 1)
        )
        XCTAssertFalse(LaunchAgentInspector.parse(list: failing)?.isRunning ?? true)
    }

    func testAnUnlistedLabelParsesAsNothing() {
        XCTAssertNil(LaunchAgentInspector.parse(list: "-\t0\tcom.example.other"))
        XCTAssertNil(LaunchAgentInspector.parse(list: ""))
        XCTAssertNil(
            LaunchAgentInspector.parse(list: "-\t0\tcom.digimata.parrot.helper"),
            "a longer label that merely starts the same is a different job"
        )
    }

    /// The pre-fix state, which is what a user upgrading into this version has
    /// on disk: a nonzero exit and launchd putting it straight back.
    func testDoctorNamesThePermissionRestartLoop() {
        let check = DoctorReport.check(
            forAgent: LaunchAgentState(pid: nil, lastExitStatus: 1),
            accessibility: .promptAlreadySpent,
            subject: ghostty
        )
        guard case .fail(let message) = check.status else {
            return XCTFail("expected a failure, got \(check.status)")
        }
        XCTAssertTrue(message.contains("not running"))
        XCTAssertTrue(message.contains("launchd keeps restarting it"), "the loop is the symptom to name")
        XCTAssertTrue(check.remediation?.contains("enable Ghostty") ?? false)
        XCTAssertTrue(check.remediation?.contains("kickstart") ?? false)
    }

    /// The post-fix state: parrot stopped on purpose, so nothing is looping and
    /// nothing will happen until someone grants the permission and reloads it.
    func testDoctorExplainsADaemonThatStoppedItself() {
        let check = DoctorReport.check(
            forAgent: LaunchAgentState(pid: nil, lastExitStatus: 0),
            accessibility: .promptAlreadySpent,
            subject: ownBinary
        )
        guard case .fail(let message) = check.status else {
            return XCTFail("expected a failure, got \(check.status)")
        }
        XCTAssertTrue(message.contains("accessibility isn't granted"))
        XCTAssertTrue(check.remediation?.contains("kickstart") ?? false)
    }

    func testDoctorReportsAHealthyAgentWithItsPID() {
        let check = DoctorReport.check(
            forAgent: LaunchAgentState(pid: 4_711, lastExitStatus: 0),
            accessibility: .granted,
            subject: ownBinary
        )
        guard case .ok = check.status else {
            return XCTFail("expected ok, got \(check.status)")
        }
        XCTAssertEqual(check.detail, "running (pid 4711)")
    }

    /// A stopped agent with the grant in place is a different problem, and must
    /// not be blamed on permissions.
    func testDoctorSendsANonPermissionFailureToTheLog() {
        let check = DoctorReport.check(
            forAgent: LaunchAgentState(pid: nil, lastExitStatus: 78),
            accessibility: .granted,
            subject: ownBinary
        )
        guard case .fail(let message) = check.status else {
            return XCTFail("expected a failure, got \(check.status)")
        }
        XCTAssertTrue(message.contains("78"))
        XCTAssertTrue(check.remediation?.contains("/tmp/parrot.err.log") ?? false)
    }

    func testDoctorFlagsAPlistThatWasNeverLoaded() {
        let check = DoctorReport.check(forAgent: nil, accessibility: .granted, subject: ownBinary)
        guard case .warn(let message) = check.status else {
            return XCTFail("expected a warning, got \(check.status)")
        }
        XCTAssertTrue(message.contains("not loaded"))
        XCTAssertTrue(check.remediation?.contains("--launch-at-login") ?? false)
    }

    func testDoctorPassesWhenGranted() {
        let check = DoctorReport.check(for: .granted, subject: ghostty)
        guard case .ok = check.status else {
            return XCTFail("expected ok, got \(check.status)")
        }
        XCTAssertNil(check.remediation)
    }

    // MARK: - The record

    private func temporaryStore() throws -> AccessibilityStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-ax-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AccessibilityStore(directory: directory)
    }

    func testMissingRecordReadsAsNothingTriedYet() throws {
        let store = try temporaryStore()
        XCTAssertEqual(store.load(), AccessibilityRecord())
    }

    func testPromptedAndGrantedSurviveARoundTrip() throws {
        let store = try temporaryStore()
        store.notePrompted()
        XCTAssertTrue(store.load().prompted)

        let identity = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        store.noteGranted(subject: ownBinary, binary: identity)
        let record = store.load()
        XCTAssertTrue(record.prompted, "recording a grant must not forget that we prompted")
        XCTAssertEqual(record.grantedSubject, ownBinary)
        XCTAssertEqual(record.grantedBinary, identity)
    }

    func testThePromptIsRememberedAgainstTheBinaryThatSpentIt() throws {
        let store = try temporaryStore()
        let first = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        store.notePrompted(binary: first)
        XCTAssertEqual(store.load().promptedBinary, first)

        let upgraded = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-2")
        XCTAssertFalse(
            store.load().hasPrompted(for: upgraded),
            "an upgraded binary is a new client to TCC, and gets its own prompt"
        )
        store.notePrompted(binary: upgraded)
        XCTAssertEqual(store.load().promptedBinary, upgraded)
        XCTAssertTrue(store.load().hasPrompted(for: upgraded))
    }

    func testRecordingAGrantKeepsWhichBinaryWasPrompted() throws {
        let store = try temporaryStore()
        let binary = BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")
        store.notePrompted(binary: binary)
        store.noteGranted(subject: ownBinary, binary: binary)
        XCTAssertEqual(store.load().promptedBinary, binary, "a grant must not reopen the prompt budget")
    }

    /// Records written by gh#31's version have `prompted` and nothing else.
    func testALegacyRecordStillDecodes() throws {
        let store = try temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"prompted":true}"#.utf8).write(to: store.fileURL)
        let record = store.load()
        XCTAssertTrue(record.prompted)
        XCTAssertNil(record.promptedBinary)
        XCTAssertTrue(
            record.hasPrompted(for: BinaryIdentity(path: "/usr/local/bin/parrot", fingerprint: "100-1")),
            "unknown provenance has to read as spent, or the storm comes back"
        )
    }

    func testCorruptRecordDegradesToDefaults() throws {
        let store = try temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), AccessibilityRecord())
    }

    func testStateDirectoryCanBeOverriddenForDebugging() {
        XCTAssertEqual(
            AccessibilityStore.defaultDirectory(environment: ["PARROT_STATE_DIR": "/tmp/parrot-state"]).path,
            "/tmp/parrot-state"
        )
        XCTAssertTrue(
            AccessibilityStore.defaultDirectory(environment: [:]).path
                .hasSuffix("Library/Application Support/parrot")
        )
    }

    func testBinaryIdentityChangesWhenContentsChange() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-bin-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try Data("v1".utf8).write(to: file)
        let first = try XCTUnwrap(BinaryIdentity.of(path: file.path))

        try Data("version two".utf8).write(to: file)
        let second = try XCTUnwrap(BinaryIdentity.of(path: file.path))

        XCTAssertEqual(first.path, second.path)
        XCTAssertNotEqual(first, second, "an in-place upgrade has to be visible")
    }

    func testBinaryIdentityOfAMissingFileIsNil() {
        XCTAssertNil(BinaryIdentity.of(path: "/nonexistent/parrot"))
    }

    // MARK: - Polling

    /// The point of polling: a toggle flipped while setup waits finishes setup,
    /// instead of demanding a re-run.
    func testPollingReturnsAsSoonAsTrustArrives() {
        var calls = 0
        var slept: [TimeInterval] = []
        let granted = AccessibilityTrust.waitForTrust(
            polls: 20,
            interval: 0.5,
            isTrusted: {
                calls += 1
                return calls >= 3
            },
            sleep: { slept.append($0) }
        )
        XCTAssertTrue(granted)
        XCTAssertEqual(calls, 3, "polling must stop at the first true")
        XCTAssertEqual(slept, [0.5, 0.5])
    }

    func testPollingGivesUpAfterTheBudgetAndChecksOnceMore() {
        var calls = 0
        let granted = AccessibilityTrust.waitForTrust(
            polls: 2,
            interval: 0.5,
            isTrusted: {
                calls += 1
                return false
            },
            sleep: { _ in }
        )
        XCTAssertFalse(granted)
        XCTAssertEqual(calls, 3, "two polls plus a final check after the last sleep")
    }

    func testPollCountsCoverTheAdvertisedWait() {
        XCTAssertEqual(AccessibilityTrust.polls(for: 4, interval: 0.5), 8)
        XCTAssertEqual(AccessibilityTrust.polls(for: 180, interval: 0.5), 360)
        XCTAssertEqual(AccessibilityTrust.polls(for: 0, interval: 0.5), 1)
    }

    func testPollingReportsProgressWithoutBlockingCompletion() {
        var polls: [Int] = []
        _ = AccessibilityTrust.waitForTrust(
            polls: 3,
            interval: 0,
            isTrusted: { false },
            sleep: { _ in },
            onPoll: { polls.append($0) }
        )
        XCTAssertEqual(polls, [0, 1, 2])
    }
}

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

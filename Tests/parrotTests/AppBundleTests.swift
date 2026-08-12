import Foundation
import XCTest
@testable import parrot

/// gh#37: the Accessibility grant only survives a rebuild because the thing
/// macOS is asked to trust is a signed bundle rather than a heap of bytes. The
/// parts of that worth pinning are the ones that decide *which* file is the
/// identity — where the bundle is, what the LaunchAgent execs, and what parrot
/// records as "the binary I was granted".
final class AppBundleTests: XCTestCase {
    private let bundled = "/Users/x/Applications/Papegøye.app/Contents/MacOS/parrot"

    // MARK: - Recognising the bundle

    func testAnExecutableInsideTheBundleReportsTheApp() {
        XCTAssertEqual(
            AppBundle.enclosing(executable: bundled),
            "/Users/x/Applications/Papegøye.app"
        )
    }

    func testABareBinaryIsNotInABundle() {
        XCTAssertNil(AppBundle.enclosing(executable: "/usr/local/bin/parrot"))
        XCTAssertNil(AppBundle.enclosing(executable: "/Users/x/.local/bin/parrot"))
    }

    /// Only the real layout counts: a directory that merely has the name in it
    /// is not a bundle, and neither is the app directory itself.
    func testNearMissesAreNotBundles() {
        XCTAssertNil(AppBundle.enclosing(executable: "/Users/x/Papegøye.app/parrot"))
        XCTAssertNil(AppBundle.enclosing(executable: "/Users/x/Papegøye.app/Contents/parrot"))
        XCTAssertNil(AppBundle.enclosing(executable: "/Users/x/Papegøye/Contents/MacOS/parrot"))
    }

    func testTheBundleIdentifierIsNotUpstreams() {
        XCTAssertEqual(AppBundle.identifier, "no.bredebjorhovd.papegoye")
        XCTAssertNotEqual(
            AppBundle.identifier, Install.label,
            "the LaunchAgent label is already com.digimata.parrot; reusing it for the bundle "
                + "would make two different things answer to one name"
        )
    }

    // MARK: - Where the LaunchAgent points

    private func daemonBinary(
        running: String? = nil,
        candidates: [String] = ["/usr/local/bin/parrot", "/Users/x/.local/bin/parrot"],
        onDisk: [String: String] = [:]
    ) -> String? {
        Install.daemonBinary(
            running: running,
            candidates: candidates,
            resolve: { onDisk[$0] }
        )
    }

    /// The point of the whole issue: the plist has to name the binary TCC
    /// grants, which is the one inside the bundle — not the symlink that got
    /// the user there.
    func testASymlinkedCLIResolvesIntoTheBundle() {
        XCTAssertEqual(
            daemonBinary(
                running: "/usr/local/bin/parrot",
                onDisk: ["/Users/x/.local/bin/parrot": bundled]
            ),
            bundled
        )
    }

    func testRunningFromInsideTheBundleWinsOutright() {
        XCTAssertEqual(
            daemonBinary(
                running: bundled,
                onDisk: ["/usr/local/bin/parrot": "/usr/local/bin/parrot"]
            ),
            bundled,
            "an unrelated binary on PATH must not displace the app that holds the grant"
        )
    }

    /// No bundle anywhere: the old rule, which is that the agent runs the
    /// `parrot` the user types rather than whatever ran `install`.
    func testWithoutABundleThePATHBinaryStillWins() {
        XCTAssertEqual(
            daemonBinary(
                running: "/Users/x/dev/papegoye/.build/release/parrot",
                onDisk: ["/usr/local/bin/parrot": "/usr/local/bin/parrot"]
            ),
            "/usr/local/bin/parrot"
        )
    }

    func testTheFirstCandidateOnDiskIsPreferred() {
        XCTAssertEqual(
            daemonBinary(onDisk: [
                "/usr/local/bin/parrot": "/usr/local/bin/parrot",
                "/Users/x/.local/bin/parrot": "/Users/x/.local/bin/parrot",
            ]),
            "/usr/local/bin/parrot"
        )
    }

    func testNothingInstalledFallsBackToTheRunningBinary() {
        XCTAssertEqual(
            daemonBinary(running: "/Users/x/dev/papegoye/.build/release/parrot"),
            "/Users/x/dev/papegoye/.build/release/parrot"
        )
        XCTAssertNil(daemonBinary())
    }

    func testBothUsualInstallDirectoriesAreLookedIn() {
        let candidates = Install.cliCandidates(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(candidates, ["/usr/local/bin/parrot", "/Users/x/.local/bin/parrot"])
    }

    // MARK: - The identity parrot records

    func testASignedBinaryIsIdentifiedByItsSignatureNotItsBytes() {
        let signature = CodeSignature(
            identifier: "no.bredebjorhovd.papegoye",
            teamID: "3ZZD9G3C62",
            authority: "Apple Development: someone@example.com (3ZZD9G3C62)",
            expiry: nil
        )
        XCTAssertEqual(
            signature.stableFingerprint,
            "signed:no.bredebjorhovd.papegoye:3ZZD9G3C62",
            "a rebuild changes every byte and none of this — which is the point"
        )
    }

    func testAnAdHocSignatureHasNoStableIdentity() {
        let adHoc = CodeSignature(
            identifier: "parrot",
            teamID: nil,
            authority: nil,
            expiry: nil
        )
        XCTAssertTrue(adHoc.isAdHoc)
        XCTAssertNil(
            adHoc.stableFingerprint,
            "ad-hoc signing keys the identity to the contents, so it has to fall back to bytes"
        )
    }

    /// The live path, on a binary every Mac has: if this stops returning a
    /// signature, `BinaryIdentity` has quietly gone back to size-and-mtime.
    func testASystemBinaryReadsAsSigned() throws {
        let signature = try XCTUnwrap(CodeSignature.of(path: "/bin/ls"))
        XCTAssertEqual(signature.identifier, "com.apple.ls")
        XCTAssertFalse(signature.isAdHoc)
        XCTAssertNotNil(signature.stableFingerprint)
    }

    func testAnUnsignedFileHasNoSignature() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-unsigned-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try Data("not a mach-o".utf8).write(to: file)
        XCTAssertNil(CodeSignature.of(path: file.path))
    }

    /// A signed binary's identity must not change when the file does — the
    /// unsigned case (contents fingerprint) is covered in AccessibilityTests.
    func testTheRecordedIdentityOfASignedBinaryIgnoresTheFileItself() throws {
        let first = try XCTUnwrap(BinaryIdentity.of(path: "/bin/ls"))
        XCTAssertTrue(
            first.fingerprint.hasPrefix("signed:"),
            "got \(first.fingerprint) — a signed binary should not be fingerprinted by size and mtime"
        )
    }

    // MARK: - What doctor says about it

    private let signed = CodeSignature(
        identifier: "no.bredebjorhovd.papegoye",
        teamID: "3ZZD9G3C62",
        authority: "Apple Development: someone@example.com (3ZZD9G3C62)",
        expiry: Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15
    )

    func testDoctorNamesTheSigningIdentityAndItsExpiry() {
        let check = DoctorReport.checkCodeSignature(signed, now: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .ok = check.status else {
            return XCTFail("a valid certificate is not a problem, got \(check.status)")
        }
        let detail = check.detail ?? ""
        XCTAssertTrue(detail.contains("no.bredebjorhovd.papegoye"))
        XCTAssertTrue(detail.contains("Apple Development"))
        XCTAssertTrue(detail.contains("2027-01-15"), "got \(detail)")
        XCTAssertNil(check.remediation)
    }

    /// The one thing worth warning about: past this date the next build signs
    /// under an identity macOS has never seen, and the grant is gone.
    func testDoctorWarnsOnceTheCertificateHasExpired() {
        let check = DoctorReport.checkCodeSignature(signed, now: Date(timeIntervalSince1970: 1_900_000_000))
        guard case .warn(let message) = check.status else {
            return XCTFail("expected a warning, got \(check.status)")
        }
        XCTAssertTrue(message.contains("expired"))
        XCTAssertTrue(check.remediation?.contains("re-grant") ?? false)
    }

    /// Unsigned is how the released tarball ships, so it must not fail or warn
    /// — `parrot doctor` exits on those — but it should say what it costs.
    func testDoctorReportsAnUnsignedBinaryWithoutCallingItBroken() {
        let check = DoctorReport.checkCodeSignature(nil, now: Date())
        guard case .ok = check.status else {
            return XCTFail("expected ok, got \(check.status)")
        }
        XCTAssertTrue(check.detail?.contains("unsigned") ?? false)
        XCTAssertTrue(check.remediation?.contains("make install") ?? false)
    }

    func testDoctorSaysAdHocSigningBuysNothing() {
        let check = DoctorReport.checkCodeSignature(
            CodeSignature(identifier: "parrot", teamID: nil, authority: nil, expiry: nil),
            now: Date()
        )
        guard case .ok = check.status else {
            return XCTFail("expected ok, got \(check.status)")
        }
        XCTAssertTrue(check.detail?.contains("ad-hoc") ?? false)
    }

    // MARK: - Double-clicking the app

    /// A Finder-launched app is a child of launchd with no terminal and
    /// `XPC_SERVICE_NAME=0` — indistinguishable from a background agent except
    /// for the identifier LaunchServices stamps into the environment. Get this
    /// wrong and opening Papegøye.app exits in silence, having decided nobody
    /// is there to answer a dialog.
    func testOpeningTheAppIsAGUISessionNotADaemon() {
        XCTAssertEqual(
            SessionKind.detect(
                environment: ["__CFBundleIdentifier": AppBundle.identifier, "XPC_SERVICE_NAME": "0"],
                parentPID: 1,
                hasTerminal: false
            ),
            .gui
        )
    }

    /// …but the agent's own marker outranks it, or gh#35's prompt storm walks
    /// back in through the bundle.
    func testTheLaunchdMarkerStillWinsInsideTheBundle() {
        XCTAssertEqual(
            SessionKind.detect(
                environment: [
                    "__CFBundleIdentifier": AppBundle.identifier,
                    Install.launchdMarkerKey: "1",
                ],
                parentPID: 1,
                hasTerminal: false
            ),
            .launchAgent
        )
    }

    func testAnotherAppsIdentifierProvesNothing() {
        XCTAssertEqual(
            SessionKind.detect(
                environment: ["__CFBundleIdentifier": "com.apple.Terminal"],
                parentPID: 1,
                hasTerminal: false
            ),
            .launchAgent,
            "an inherited identifier from whatever opened the terminal is not a launch of ours"
        )
    }

    // MARK: - What the user is told to toggle

    func testTheBundleIsWhatTheUserAddsToTheAccessibilityList() {
        let subject = AccessibilitySubject.ownBinary(path: bundled)
        XCTAssertEqual(subject.displayName, "Papegøye")
        XCTAssertEqual(subject.grantPath, "/Users/x/Applications/Papegøye.app")

        let lines = AccessibilityGuidance.instructions(for: .notYetPrompted, subject: subject)
            .joined(separator: "\n")
        XCTAssertTrue(lines.contains("/Users/x/Applications/Papegøye.app"))
        XCTAssertFalse(
            lines.contains("Contents/MacOS"),
            "the + dialog takes the app, not the executable buried inside it"
        )
    }

    func testAnUnbundledBinaryIsStillNamedAsItself() {
        let subject = AccessibilitySubject.ownBinary(path: "/usr/local/bin/parrot")
        XCTAssertEqual(subject.displayName, "parrot")
        XCTAssertEqual(subject.grantPath, "/usr/local/bin/parrot")
    }
}

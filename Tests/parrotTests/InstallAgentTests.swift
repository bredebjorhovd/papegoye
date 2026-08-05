import ArgumentParser
import Foundation
import XCTest
@testable import parrot

/// The LaunchAgent plist is the only place where an `install` invocation has to
/// survive a reboot, so these tests pin both halves of it: the forwarded run
/// flags and the environment the daemon can't inherit from a shell (gh#28).
final class InstallAgentTests: XCTestCase {
    private let binary = "/usr/local/bin/parrot"

    private func arguments(
        model: String? = nil,
        bilingual: Bool = false,
        noModel: String = BilingualConfiguration.defaultNorwegianModelID,
        enModel: String = BilingualConfiguration.defaultEnglishModelID,
        enThreshold: Float = RoutingPolicy.defaultEnglishThreshold,
        noOverlay: Bool = false,
        inputDevice: InputDevicePolicy.Preference = .auto
    ) -> [String] {
        Install.programArguments(
            binary: binary,
            model: model,
            bilingual: bilingual,
            noModel: noModel,
            enModel: enModel,
            enThreshold: enThreshold,
            noOverlay: noOverlay,
            inputDevice: inputDevice
        )
    }

    // MARK: - ProgramArguments

    func testDefaultInstallRunsTheDaemonUnchanged() {
        XCTAssertEqual(arguments(), [binary, "run", "--skip-doctor"])
    }

    func testBilingualIsForwarded() {
        XCTAssertEqual(
            arguments(bilingual: true),
            [binary, "run", "--skip-doctor", "--bilingual"]
        )
    }

    func testBilingualModelOverridesAreForwarded() {
        XCTAssertEqual(
            arguments(
                bilingual: true,
                noModel: "nb-whisper-base",
                enModel: "whisper-small.en",
                enThreshold: 0.7
            ),
            [
                binary, "run", "--skip-doctor", "--bilingual",
                "--no-model", "nb-whisper-base",
                "--en-threshold", "0.7",
            ],
            "en-model at its default shouldn't be pinned into the plist"
        )
    }

    func testSingleModelAndOverlayFlagsAreForwarded() {
        XCTAssertEqual(
            arguments(model: "whisper-small.en", noOverlay: true),
            [binary, "run", "--skip-doctor", "--model", "whisper-small.en", "--no-overlay"]
        )
    }

    func testInputDeviceIsForwardedOnlyWhenItIsntTheDefault() {
        XCTAssertFalse(
            arguments(inputDevice: .auto).contains("--input-device"),
            "auto is the default, so the agent should track it rather than pin it"
        )
        XCTAssertEqual(
            arguments(inputDevice: .systemDefault),
            [binary, "run", "--skip-doctor", "--input-device", "default"]
        )
        XCTAssertEqual(
            arguments(inputDevice: .named("Shure MV7")),
            [binary, "run", "--skip-doctor", "--input-device", "Shure MV7"]
        )
    }

    /// The forwarded arguments are worthless if `parrot run` won't accept them
    /// at login, so parse them back through the real command.
    func testForwardedArgumentsParseAsRun() throws {
        let args = arguments(
            bilingual: true,
            noModel: "nb-whisper-base",
            enModel: "whisper-base.en",
            enThreshold: 0.75
        )
        let run = try Run.parse(Array(args.dropFirst(2)))
        XCTAssertTrue(run.skipDoctor)
        XCTAssertTrue(run.bilingual)
        XCTAssertEqual(run.noModel, "nb-whisper-base")
        XCTAssertEqual(run.enModel, "whisper-base.en")
        XCTAssertEqual(run.enThreshold, 0.75)
    }

    func testForwardedSingleModelArgumentsParseAsRun() throws {
        let args = arguments(model: "whisper-large-v3-turbo", noOverlay: true)
        let run = try Run.parse(Array(args.dropFirst(2)))
        XCTAssertEqual(run.model, "whisper-large-v3-turbo")
        XCTAssertTrue(run.noOverlay)
        XCTAssertFalse(run.bilingual)
    }

    func testForwardedInputDeviceParsesAsRun() throws {
        // A device name with a space is the normal case ("Shure MV7"), and it
        // only survives the plist because ProgramArguments is a real array.
        let args = arguments(inputDevice: .named("Shure MV7"))
        let run = try Run.parse(Array(args.dropFirst(2)))
        XCTAssertEqual(run.inputDevice, .named("Shure MV7"))

        let asDefault = try Run.parse(
            Array(arguments(inputDevice: .systemDefault).dropFirst(2))
        )
        XCTAssertEqual(asDefault.inputDevice, .systemDefault)
    }

    func testRunDefaultsToAvoidingBluetooth() throws {
        XCTAssertEqual(try Run.parse([]).inputDevice, .auto)
    }

    func testInstallRejectsAnEmptyInputDevice() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--input-device", "  "]),
            "an empty name would silently mean 'auto'"
        )
    }

    func testInputDeviceIsRejectedWithUninstall() {
        XCTAssertThrowsError(
            try Install.parse(["--uninstall", "--input-device", "default"])
        )
    }

    // MARK: - EnvironmentVariables

    func testEnvironmentCapturesTheNorwegianModelFolder() {
        XCTAssertEqual(
            Install.forwardedEnvironment(from: [
                "PARROT_NB_MODEL_FOLDER": "/Users/x/models/nb-whisper-small",
                "PATH": "/usr/bin",
                "HOME": "/Users/x",
            ]),
            ["PARROT_NB_MODEL_FOLDER": "/Users/x/models/nb-whisper-small"],
            "only the model folder is worth baking in; the rest is the shell's business"
        )
    }

    func testUnsetOrEmptyEnvironmentCapturesNothing() {
        XCTAssertTrue(Install.forwardedEnvironment(from: [:]).isEmpty)
        XCTAssertTrue(
            Install.forwardedEnvironment(from: ["PARROT_NB_MODEL_FOLDER": ""]).isEmpty
        )
    }

    // MARK: - Plist

    func testPlistOmitsEnvironmentVariablesWhenNothingWasCaptured() {
        let plist = Install.makePlist(arguments: arguments(), environment: [:])
        XCTAssertNil(plist["EnvironmentVariables"])
    }

    func testPlistRoundTripsThroughXMLSerialization() throws {
        let args = arguments(bilingual: true, enThreshold: 0.7)
        let env = ["PARROT_NB_MODEL_FOLDER": "/Users/x/models/nb-whisper-small"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: Install.makePlist(arguments: args, environment: env),
            format: .xml,
            options: 0
        )
        let readBack = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(readBack["Label"] as? String, "com.digimata.parrot")
        XCTAssertEqual(readBack["ProgramArguments"] as? [String], args)
        XCTAssertEqual(readBack["EnvironmentVariables"] as? [String: String], env)
        XCTAssertEqual(readBack["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(readBack["ProcessType"] as? String, "Interactive")
    }

    // MARK: - Install-time validation

    func testUnknownNorwegianModelIsRejectedAtInstallTime() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--bilingual", "--no-model", "nb-whisper-xl"])
        )
    }

    func testUnknownEnglishModelIsRejectedAtInstallTime() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--bilingual", "--en-model", "whisper-huge"])
        )
    }

    func testUnknownSingleModelIsRejectedAtInstallTime() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--model", "whisper-huge"])
        )
    }

    func testKnownBilingualModelsAreAccepted() throws {
        let install = try Install.parse([
            "--launch-at-login", "--bilingual",
            "--no-model", "nb-whisper-base",
            "--en-model", "whisper-base.en",
        ])
        XCTAssertTrue(install.bilingual)
        XCTAssertEqual(install.noModel, "nb-whisper-base")
        XCTAssertEqual(install.enModel, "whisper-base.en")
    }

    func testBilingualOptionsRequireBilingual() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--en-model", "whisper-base.en"])
        )
    }

    func testModelConflictsWithBilingual() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--bilingual", "--model", "whisper-base.en"])
        )
    }

    func testThresholdMustBeAProbability() {
        XCTAssertThrowsError(
            try Install.parse(["--launch-at-login", "--bilingual", "--en-threshold", "1.5"])
        )
    }

    func testRunFlagsAreRejectedWithUninstall() {
        XCTAssertThrowsError(try Install.parse(["--uninstall", "--bilingual"]))
    }

    func testExactlyOneModeIsRequired() {
        XCTAssertThrowsError(try Install.parse([]))
        XCTAssertThrowsError(try Install.parse(["--launch-at-login", "--uninstall"]))
    }
}

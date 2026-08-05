import CoreAudio
import XCTest
@testable import parrot

/// Table-driven tests for input-device selection — the pure
/// (device list, system default, preference) → device function (gh#30).
///
/// The whole point of splitting `InputDevicePolicy` from `AudioDevices` is that
/// this file needs no microphone, no Bluetooth headset, and no audio system.
final class InputDevicePolicyTests: XCTestCase {
    // A stable cast of devices to select from.
    private let builtIn = InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
    private let airpods = InputDevice(id: 2, name: "AirPods", transport: .bluetooth)
    private let usbMic = InputDevice(id: 3, name: "Shure MV7", transport: .usb)
    private let blackHole = InputDevice(id: 4, name: "BlackHole 2ch", transport: .virtual)
    private let iphone = InputDevice(id: 5, name: "Brede's iPhone Microphone", transport: .other)

    private func select(
        _ devices: [InputDevice],
        default defaultID: UInt32?,
        _ preference: InputDevicePolicy.Preference = .auto
    ) -> InputSelection {
        InputDevicePolicy.select(
            devices: devices,
            defaultDeviceID: defaultID,
            preference: preference
        )
    }

    // MARK: - The default policy

    func testNonBluetoothDefaultIsLeftAlone() {
        let selection = select([builtIn, airpods], default: builtIn.id)
        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .systemDefault)
        XCTAssertFalse(selection.overridesSystemDefault)
    }

    func testBluetoothDefaultFallsBackToBuiltIn() {
        let selection = select([builtIn, airpods], default: airpods.id)
        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .avoidedBluetooth(airpods))
        XCTAssertTrue(selection.overridesSystemDefault)
    }

    func testBuiltInWinsOverUSBWhenAvoidingBluetooth() {
        // Not because USB is a worse mic — because built-in is the one input
        // we can be sure is real and present. A USB mic gets picked by name.
        let selection = select([usbMic, builtIn, airpods], default: airpods.id)
        XCTAssertEqual(selection.device, builtIn)
    }

    func testUSBIsUsedWhenThereIsNoBuiltIn() {
        let selection = select([airpods, usbMic], default: airpods.id)
        XCTAssertEqual(selection.device, usbMic)
        XCTAssertEqual(selection.reason, .avoidedBluetooth(airpods))
    }

    func testMiscTransportBeatsNothingAtAll() {
        let selection = select([airpods, iphone], default: airpods.id)
        XCTAssertEqual(selection.device, iphone)
    }

    func testVirtualDevicesAreNeverAutoPicked() {
        // A loopback device can be silent, and silence is a worse failure than
        // a compressed mic — so the headset stays.
        let selection = select([airpods, blackHole], default: airpods.id)
        XCTAssertEqual(selection.device, airpods)
        XCTAssertEqual(selection.reason, .bluetoothUnavoidable)
        XCTAssertFalse(selection.overridesSystemDefault)
    }

    func testBluetoothIsKeptWhenItIsTheOnlyInput() {
        let selection = select([airpods], default: airpods.id)
        XCTAssertEqual(selection.device, airpods)
        XCTAssertEqual(selection.reason, .bluetoothUnavoidable)
    }

    func testBluetoothDefaultIsNotSwappedForAnotherBluetoothDevice() {
        let otherBT = InputDevice(id: 9, name: "WH-1000XM4", transport: .bluetooth)
        let selection = select([airpods, otherBT], default: airpods.id)
        XCTAssertEqual(selection.device, airpods)
        XCTAssertEqual(selection.reason, .bluetoothUnavoidable)
    }

    func testTiesGoToTheFirstDeviceInEnumerationOrder() {
        let secondUSB = InputDevice(id: 8, name: "Yeti", transport: .usb)
        let selection = select([airpods, usbMic, secondUSB], default: airpods.id)
        XCTAssertEqual(selection.device, usbMic)
    }

    // MARK: - Explicit overrides

    func testSystemDefaultPreferenceHonoursABluetoothDefault() {
        let selection = select([builtIn, airpods], default: airpods.id, .systemDefault)
        XCTAssertEqual(selection.device, airpods)
        XCTAssertEqual(selection.reason, .systemDefaultRequested)
        XCTAssertFalse(selection.overridesSystemDefault)
    }

    func testNamedDeviceIsSelectedEvenWhenBluetooth() {
        let selection = select([builtIn, airpods], default: builtIn.id, .named("AirPods"))
        XCTAssertEqual(selection.device, airpods)
        XCTAssertEqual(selection.reason, .explicit)
        XCTAssertTrue(selection.overridesSystemDefault)
    }

    func testNamedMatchingIsCaseAndWhitespaceInsensitive() {
        for spelling in ["shure mv7", "SHURE MV7", "  Shure MV7  "] {
            let selection = select([builtIn, usbMic], default: builtIn.id, .named(spelling))
            XCTAssertEqual(selection.device, usbMic, "should match \"\(spelling)\"")
        }
    }

    func testNamedMatchingAcceptsAPrefixOrSubstring() {
        XCTAssertEqual(
            select([builtIn, usbMic], default: builtIn.id, .named("Shure")).device,
            usbMic
        )
        XCTAssertEqual(
            select([builtIn, usbMic], default: builtIn.id, .named("MV7")).device,
            usbMic
        )
    }

    func testExactMatchWinsOverASubstringMatch() {
        let exact = InputDevice(id: 7, name: "Mic", transport: .usb)
        let substring = InputDevice(id: 6, name: "Some Other Mic Thing", transport: .usb)
        // `substring` comes first in enumeration order, so only the tiering
        // stops it from winning.
        let selection = select([substring, exact], default: builtIn.id, .named("Mic"))
        XCTAssertEqual(selection.device, exact)
    }

    func testUnmatchedNameFallsBackToTheAutomaticPickAndSaysSo() {
        let selection = select([builtIn, airpods], default: airpods.id, .named("Yeti"))
        XCTAssertEqual(selection.reason, .noMatch("Yeti"))
        XCTAssertTrue(selection.isFailure, "an unhonoured request is a doctor failure")
        XCTAssertEqual(
            selection.device, builtIn,
            "still record from something sensible rather than refusing to record"
        )
    }

    func testNoDevicesAtAll() {
        let selection = select([], default: nil)
        XCTAssertNil(selection.device)
        XCTAssertEqual(selection.reason, .noDevices)
        XCTAssertFalse(selection.isFailure)
    }

    func testDefaultDeviceMissingFromTheList() {
        let selection = select([builtIn], default: 999)
        XCTAssertNil(selection.device)
        XCTAssertEqual(selection.reason, .noDevices)
    }

    // MARK: - What the user is told

    func testTheLogLineNamesTheSkippedBluetoothDevice() {
        let line = select([builtIn, airpods], default: airpods.id).logLine
        XCTAssertTrue(line.hasPrefix("○ input: MacBook Pro Microphone"), line)
        XCTAssertTrue(line.contains("skipped Bluetooth \"AirPods\""), line)
        XCTAssertTrue(line.contains("HFP"), line)
        XCTAssertTrue(
            line.contains("--input-device default"),
            "must say how to get the headset back: \(line)"
        )
        XCTAssertTrue(line.hasSuffix("\n"), "log lines terminate themselves")
    }

    func testEveryReasonNamesTheDeviceItPicked() {
        let selections = [
            select([builtIn, airpods], default: builtIn.id),
            select([builtIn, airpods], default: airpods.id),
            select([airpods], default: airpods.id),
            select([builtIn, airpods], default: airpods.id, .systemDefault),
            select([builtIn, airpods], default: builtIn.id, .named("AirPods")),
            select([builtIn, airpods], default: airpods.id, .named("Yeti")),
        ]
        for selection in selections {
            guard let device = selection.device else { continue }
            XCTAssertTrue(
                selection.description.contains(device.name),
                "\(selection.reason) should name \(device.name): \(selection.description)"
            )
        }
    }

    func testBluetoothOverridesWarnAboutHFP() {
        // Choosing the headset explicitly is allowed — but not silently.
        let explicit = select([builtIn, airpods], default: builtIn.id, .named("AirPods"))
        XCTAssertTrue(explicit.description.contains("HFP"), explicit.description)

        let requested = select([builtIn, airpods], default: airpods.id, .systemDefault)
        XCTAssertTrue(requested.description.contains("HFP"), requested.description)
    }

    // MARK: - Preference parsing

    func testPreferenceParsing() {
        XCTAssertEqual(InputDevicePolicy.Preference.parse("auto"), .auto)
        XCTAssertEqual(InputDevicePolicy.Preference.parse("default"), .systemDefault)
        XCTAssertEqual(InputDevicePolicy.Preference.parse("DEFAULT"), .systemDefault)
        XCTAssertEqual(InputDevicePolicy.Preference.parse("system-default"), .systemDefault)
        XCTAssertEqual(InputDevicePolicy.Preference.parse("AirPods"), .named("AirPods"))
        XCTAssertEqual(InputDevicePolicy.Preference.parse("  AirPods  "), .named("AirPods"))
        XCTAssertNil(InputDevicePolicy.Preference.parse("   "), "empty is a parse error, not auto")
    }

    func testPreferenceRoundTripsThroughACommandLine() {
        XCTAssertNil(
            InputDevicePolicy.Preference.auto.commandLineValue,
            "the default shouldn't be pinned into a plist"
        )
        for preference: InputDevicePolicy.Preference in [.systemDefault, .named("Shure MV7")] {
            let value = preference.commandLineValue
            XCTAssertNotNil(value)
            XCTAssertEqual(InputDevicePolicy.Preference.parse(value!), preference)
        }
    }

    // MARK: - CoreAudio transport mapping

    func testTransportTypeMapping() {
        let cases: [(UInt32, InputDevice.Transport)] = [
            (kAudioDeviceTransportTypeBluetooth, .bluetooth),
            (kAudioDeviceTransportTypeBluetoothLE, .bluetooth),
            (kAudioDeviceTransportTypeBuiltIn, .builtIn),
            (kAudioDeviceTransportTypeUSB, .usb),
            (kAudioDeviceTransportTypeVirtual, .virtual),
            (kAudioDeviceTransportTypeAggregate, .virtual),
            (kAudioDeviceTransportTypeThunderbolt, .other),
            (kAudioDeviceTransportTypeUnknown, .other),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(InputDevice.Transport(coreAudioTransportType: raw), expected)
        }
    }

    func testOnlyBluetoothIsTreatedAsBluetooth() {
        let transports: [InputDevice.Transport] = [.builtIn, .usb, .virtual, .other]
        for transport in transports {
            XCTAssertFalse(transport.isBluetooth, "\(transport)")
        }
        XCTAssertTrue(InputDevice.Transport.bluetooth.isBluetooth)
    }
}

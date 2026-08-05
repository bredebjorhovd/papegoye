import Foundation

/// One audio input device, as much of it as the selection policy cares about.
///
/// Deliberately free of CoreAudio types so the policy below is a pure function
/// over a plain list and can be table-tested without a microphone
/// (`AudioDevices` does the hardware half).
struct InputDevice: Equatable {
    /// CoreAudio's `AudioDeviceID`, kept as its underlying type.
    let id: UInt32
    let name: String
    let transport: Transport

    /// The transport classes that change what we do. Everything CoreAudio
    /// reports that isn't one of these lands in `.other`.
    enum Transport: Equatable {
        case builtIn
        case bluetooth
        case usb
        /// Virtual and aggregate devices — BlackHole, Loopback, the audio
        /// device a meeting app installs. Never auto-picked: they can be
        /// silent, and a silent mic is worse than a compressed one.
        case virtual
        case other

        var isBluetooth: Bool { self == .bluetooth }

        /// How willing we are to fall back to this device when the system
        /// default is Bluetooth. Higher wins; 0 means never auto-pick.
        ///
        /// Built-in comes first because it is the one input we know is a real,
        /// clean, always-present microphone. A USB mic beats the miscellaneous
        /// rest (Thunderbolt, HDMI, Continuity) but loses to built-in: if the
        /// user wanted the USB one specifically, `--input-device` says so.
        var fallbackRank: Int {
            switch self {
            case .builtIn: return 3
            case .usb: return 2
            case .other: return 1
            case .virtual, .bluetooth: return 0
            }
        }
    }
}

/// The outcome of picking a microphone: which device, and why that one.
struct InputSelection: Equatable {
    /// The device to record from. `nil` means "leave the engine on whatever
    /// macOS considers the default" — either because we couldn't enumerate
    /// anything, or because the request matched nothing.
    let device: InputDevice?
    let reason: Reason
    /// True when `device` is not the system default input, i.e. we quietly
    /// went somewhere the user didn't point us. Always accompanied by a log
    /// line saying so.
    let overridesSystemDefault: Bool

    enum Reason: Equatable {
        /// `--input-device <name>` matched this device.
        case explicit
        /// `--input-device default` — plain system-default behaviour.
        case systemDefaultRequested
        /// Auto: the system default isn't Bluetooth, so it's fine as-is.
        case systemDefault
        /// Auto: the system default was the carried Bluetooth device, and we
        /// went elsewhere.
        case avoidedBluetooth(InputDevice)
        /// Auto: the system default is Bluetooth and there is nothing else.
        case bluetoothUnavoidable
        /// Nothing to choose from — no input devices, or no default.
        case noDevices
        /// `--input-device <name>` matched nothing; `device` is the automatic
        /// pick instead.
        case noMatch(String)
    }

    /// True when the user's explicit request could not be honoured. Worth a
    /// warning and a failed doctor check — but not worth refusing to record:
    /// a hold-to-talk daemon that dies because a USB mic is unplugged is worse
    /// than one that records from the built-in and says so.
    var isFailure: Bool {
        if case .noMatch = reason { return true }
        return false
    }

    /// Human-readable summary: which mic, and what decision produced it.
    ///
    /// Silently ignoring the user's chosen microphone would be its own bug, so
    /// every branch that departs from the system default says which device it
    /// skipped and how to get it back.
    var description: String {
        switch reason {
        case .explicit:
            let name = device?.name ?? "unknown"
            if device?.transport.isBluetooth == true {
                return "\(name) (--input-device; Bluetooth — recording will pull it into HFP)"
            }
            return "\(name) (--input-device)"
        case .systemDefaultRequested:
            let name = device?.name ?? "system default"
            if device?.transport.isBluetooth == true {
                return "\(name) (--input-device default; Bluetooth — recording will pull it into HFP)"
            }
            return "\(name) (--input-device default)"
        case .systemDefault:
            return "\(device?.name ?? "system default") (system default)"
        case .avoidedBluetooth(let skipped):
            return "\(device?.name ?? "system default") "
                + "(skipped Bluetooth \"\(skipped.name)\" — would force HFP; "
                + "--input-device default to use it anyway)"
        case .bluetoothUnavoidable:
            return "\(device?.name ?? "system default") "
                + "(Bluetooth, and the only input available — playback through it may distort)"
        case .noDevices:
            return "system default (couldn't enumerate input devices)"
        case .noMatch(let requested):
            guard let device else {
                return "system default (no input device matches \"\(requested)\")"
            }
            return "\(device.name) (no input device matches \"\(requested)\" — "
                + "using the automatic pick instead)"
        }
    }

    /// The startup/per-capture stderr line, in the daemon's `○` house style.
    var logLine: String { "○ input: \(description)\n" }
}

/// Picks the microphone to record from.
///
/// The reason this is a policy and not just "use the default": classic
/// Bluetooth can't carry stereo A2DP playback and a mic at the same time, so
/// opening a connected headset's mic drops the whole link to HFP — 16 kHz mono,
/// compressed, and audibly wrecked for whatever was playing (gh#30). The
/// headset mic is also the *worse* mic for transcription, so the trade is
/// lopsided and avoiding it is the right default rather than a flag.
enum InputDevicePolicy {
    /// What the user asked for on the command line.
    enum Preference: Equatable {
        /// Avoid a Bluetooth default when there's anything else. The default.
        case auto
        /// Whatever macOS considers the default input, Bluetooth or not.
        case systemDefault
        /// A device named on the command line.
        case named(String)

        /// Parse `--input-device`'s argument. `nil` for an empty string so the
        /// argument parser can reject it rather than silently meaning `auto`.
        static func parse(_ argument: String) -> Preference? {
            let trimmed = argument.trimmingCharacters(in: .whitespaces)
            switch trimmed.lowercased() {
            case "": return nil
            case "auto": return .auto
            case "default", "system", "system-default": return .systemDefault
            default: return .named(trimmed)
            }
        }

        /// How this preference is written back on a command line, for
        /// forwarding into the LaunchAgent plist. `nil` when it's the default
        /// and so doesn't need pinning.
        var commandLineValue: String? {
            switch self {
            case .auto: return nil
            case .systemDefault: return "default"
            case .named(let name): return name
            }
        }
    }

    /// Pure selection over an enumerated device list.
    ///
    /// - Parameters:
    ///   - devices: every input device, in CoreAudio's enumeration order.
    ///   - defaultDeviceID: the system default input, if there is one.
    ///   - preference: what the user asked for.
    static func select(
        devices: [InputDevice],
        defaultDeviceID: UInt32?,
        preference: Preference = .auto
    ) -> InputSelection {
        if case .named(let requested) = preference {
            guard let match = match(requested, in: devices) else {
                // Keep the automatic pick's device, replace its reason: the
                // headline is that we couldn't do what was asked.
                let fallback = select(
                    devices: devices,
                    defaultDeviceID: defaultDeviceID,
                    preference: .auto
                )
                return InputSelection(
                    device: fallback.device,
                    reason: .noMatch(requested),
                    overridesSystemDefault: fallback.overridesSystemDefault
                )
            }
            return InputSelection(
                device: match,
                reason: .explicit,
                overridesSystemDefault: match.id != defaultDeviceID
            )
        }

        guard let defaultDeviceID, let current = devices.first(where: { $0.id == defaultDeviceID }) else {
            return InputSelection(device: nil, reason: .noDevices, overridesSystemDefault: false)
        }

        if preference == .systemDefault {
            return InputSelection(
                device: current,
                reason: .systemDefaultRequested,
                overridesSystemDefault: false
            )
        }

        guard current.transport.isBluetooth else {
            return InputSelection(
                device: current,
                reason: .systemDefault,
                overridesSystemDefault: false
            )
        }

        guard let alternative = bestAlternative(in: devices) else {
            return InputSelection(
                device: current,
                reason: .bluetoothUnavoidable,
                overridesSystemDefault: false
            )
        }
        return InputSelection(
            device: alternative,
            reason: .avoidedBluetooth(current),
            overridesSystemDefault: true
        )
    }

    /// Highest-ranked device we're willing to auto-pick, ties going to the
    /// first in enumeration order. `min(by:)` over the reversed rank keeps that
    /// tie-break — it only replaces the incumbent on a strict improvement.
    private static func bestAlternative(in devices: [InputDevice]) -> InputDevice? {
        devices
            .filter { $0.transport.fallbackRank > 0 }
            .min { $0.transport.fallbackRank > $1.transport.fallbackRank }
    }

    /// Name matching, loosest tier last: an exact name wins over a prefix,
    /// a prefix over a substring. Case- and whitespace-insensitive throughout,
    /// because nobody types "MacBook Pro Microphone" with the capitals right.
    private static func match(_ requested: String, in devices: [InputDevice]) -> InputDevice? {
        let needle = requested.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let names = devices.map { $0.name.lowercased() }

        if let i = names.firstIndex(of: needle) { return devices[i] }
        if let i = names.firstIndex(where: { $0.hasPrefix(needle) }) { return devices[i] }
        if let i = names.firstIndex(where: { $0.contains(needle) }) { return devices[i] }
        return nil
    }
}

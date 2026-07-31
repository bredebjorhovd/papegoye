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
}

enum DoctorReport {
    /// `models` — the active configuration's model set (three in bilingual
    /// mode). Missing downloads are a warning, not a failure: warmup will
    /// download them, but on a slow link you'd rather know up front.
    static func run(models: [TranscriptionModel] = []) -> [Check] {
        var checks = [
            checkMicrophone(),
            checkAccessibility(),
            checkFnKeyMapping(),
        ]
        for m in models {
            checks.append(checkModelDownloaded(m))
        }
        return checks
    }

    /// WhisperKit (via swift-transformers' HubApi) downloads models to
    /// ~/Documents/huggingface/models/<repo>/<variant>. A model with an
    /// explicit `modelFolder` is checked at that path instead.
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
        let repo = model.modelRepo ?? "argmaxinc/whisperkit-coreml"
        let repoDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/\(repo)")
        // WhisperKit fuzzy-matches variant folder names on download, so
        // accept any non-empty folder whose name contains the variant.
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: repoDir.path)) ?? []
        let found = candidates.contains { $0.contains(variant) && directoryNonEmpty(repoDir.appendingPathComponent($0).path) }
        if found {
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
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for your terminal"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        let parent = parentProcessName() ?? "your terminal"
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation: "System Settings → Privacy & Security → Accessibility → enable for \(parent)"
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

    private static func parentProcessName() -> String? {
        let ppid = getppid()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(ppid), "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return (s as NSString).lastPathComponent
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
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

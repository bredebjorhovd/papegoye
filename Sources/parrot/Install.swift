import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    // Run flags forwarded into the agent's ProgramArguments. These mirror
    // `parrot run` — whatever you'd type in a terminal tab is what the daemon
    // gets at login.

    @Option(name: .long, help: "Model id the agent should run. Defaults to the recommended model.")
    var model: String?

    @Flag(name: .long, help: "Run the agent in bilingual mode (Norwegian/English routing).")
    var bilingual: Bool = false

    @Option(name: .customLong("no-model"), help: "Bilingual: model for the Norwegian route.")
    var noModel: String = BilingualConfiguration.defaultNorwegianModelID

    @Option(name: .customLong("en-model"), help: "Bilingual: model for the English route.")
    var enModel: String = BilingualConfiguration.defaultEnglishModelID

    @Option(name: .customLong("en-threshold"), help: "Bilingual: LID confidence gate for the English route (0-1).")
    var enThreshold: Float = RoutingPolicy.defaultEnglishThreshold

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    func validate() throws {
        if launchAtLogin == uninstall {
            throw ValidationError("specify exactly one of --launch-at-login or --uninstall")
        }
        if uninstall, !runFlagsAreDefault {
            throw ValidationError("run flags don't apply to --uninstall.")
        }
        if bilingual, model != nil {
            throw ValidationError("--model conflicts with --bilingual; use --no-model / --en-model instead.")
        }
        if !bilingual {
            if noModel != BilingualConfiguration.defaultNorwegianModelID
                || enModel != BilingualConfiguration.defaultEnglishModelID
                || enThreshold != RoutingPolicy.defaultEnglishThreshold
            {
                throw ValidationError("--no-model / --en-model / --en-threshold require --bilingual.")
            }
        }
        if bilingual, !(0...1).contains(enThreshold) {
            throw ValidationError("--en-threshold must be between 0 and 1.")
        }

        // Resolve model ids here, not at next login: a LaunchAgent that fails
        // to start writes to /tmp/parrot.err.log and nowhere the user looks.
        if bilingual {
            _ = try BilingualConfiguration(
                norwegianModelID: noModel,
                englishModelID: enModel,
                englishThreshold: enThreshold
            )
        } else if let model, ModelRegistry.find(model) == nil {
            throw ValidationError(
                "unknown model: \(model) — run `parrot models list` to see options."
            )
        }
    }

    func run() throws {
        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    private var runFlagsAreDefault: Bool {
        model == nil
            && !bilingual
            && !noOverlay
            && noModel == BilingualConfiguration.defaultNorwegianModelID
            && enModel == BilingualConfiguration.defaultEnglishModelID
            && enThreshold == RoutingPolicy.defaultEnglishThreshold
    }

    // MARK: - Plist construction (pure)

    static let label = "com.digimata.parrot"

    /// Environment the daemon cannot inherit from a shell but still needs.
    ///
    /// A LaunchAgent starts with an essentially empty environment, so a local
    /// NB-Whisper conversion — reachable only via `PARROT_NB_MODEL_FOLDER`
    /// until #2 publishes the CoreML artifacts — has to be baked into the
    /// plist at install time or the Norwegian route can't warm up.
    static let forwardedEnvironmentKeys = ["PARROT_NB_MODEL_FOLDER"]

    /// The arguments the agent runs with: `run --skip-doctor` plus whatever
    /// run flags `install` was invoked with. Only non-default values are
    /// forwarded, so the agent tracks parrot's defaults the way a bare
    /// `parrot run` in a terminal would.
    static func programArguments(
        binary: String,
        model: String?,
        bilingual: Bool,
        noModel: String,
        enModel: String,
        enThreshold: Float,
        noOverlay: Bool
    ) -> [String] {
        var args = [binary, "run", "--skip-doctor"]
        if let model {
            args += ["--model", model]
        }
        if bilingual {
            args.append("--bilingual")
            if noModel != BilingualConfiguration.defaultNorwegianModelID {
                args += ["--no-model", noModel]
            }
            if enModel != BilingualConfiguration.defaultEnglishModelID {
                args += ["--en-model", enModel]
            }
            if enThreshold != RoutingPolicy.defaultEnglishThreshold {
                args += ["--en-threshold", "\(enThreshold)"]
            }
        }
        if noOverlay {
            args.append("--no-overlay")
        }
        return args
    }

    /// The subset of `environment` worth capturing into the plist.
    static func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
        var captured: [String: String] = [:]
        for key in forwardedEnvironmentKeys {
            if let value = environment[key], !value.isEmpty {
                captured[key] = value
            }
        }
        return captured
    }

    static func makePlist(
        arguments: [String],
        environment: [String: String]
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/parrot.out.log",
            "StandardErrorPath": "/tmp/parrot.err.log",
        ]
        // Omit the key entirely rather than writing an empty dict — a reader
        // shouldn't have to wonder whether an empty dict meant something.
        if !environment.isEmpty {
            plist["EnvironmentVariables"] = environment
        }
        return plist
    }

    // MARK: -

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()
        let arguments = Self.programArguments(
            binary: binary,
            model: model,
            bilingual: bilingual,
            noModel: noModel,
            enModel: enModel,
            enThreshold: enThreshold,
            noOverlay: noOverlay
        )
        let environment = Self.forwardedEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        let plist = Self.makePlist(arguments: arguments, environment: environment)

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  args:   \(arguments.dropFirst().joined(separator: " "))")
        if environment.isEmpty {
            print("  env:    none")
        } else {
            // Say out loud what got baked in — a plist that silently captured
            // a path from one shell is worse than one that announces it.
            for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
                print("  env:    \(key)=\(value)")
                if !FileManager.default.fileExists(atPath: value) {
                    FileHandle.standardError.write(Data(
                        "warning: \(key) points at \(value), which doesn't exist right now.\n".utf8
                    ))
                }
            }
            print("  (baked in from this shell; re-run `parrot install` after moving the model)")
        }
        print("  logs:   /tmp/parrot.out.log, /tmp/parrot.err.log")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path, but ~/.local/bin
        // (or anything on PATH) is equally valid — the agent must point at the
        // binary the user actually runs, wherever that is.
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Resolve the running executable, following PATH and symlinks. argv0 is
        // just "parrot" when invoked via PATH, so look it up directly.
        if let running = ExecutablePath.current(), FileManager.default.isExecutableFile(atPath: running) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(running)\n".utf8
            ))
            return running
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}

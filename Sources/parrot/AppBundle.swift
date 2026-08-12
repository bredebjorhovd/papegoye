import Foundation

/// What parrot knows about being installed as `Papegøye.app` (gh#37).
///
/// The command stays `parrot` — `~/.local/bin/parrot` is a symlink into the
/// bundle — but the *identity* macOS grants permissions to is the signed app,
/// so anything that names the thing a user has to toggle, or that the
/// LaunchAgent has to exec, goes through here.
enum AppBundle {
    /// Deliberately not `com.digimata.parrot`: that is upstream's, and it is
    /// already the LaunchAgent label.
    static let identifier = "no.bredebjorhovd.papegoye"

    /// How the app names itself in the Accessibility list.
    static let displayName = "Papegøye"

    static let directoryName = "Papegøye.app"

    /// The `.app` an executable lives inside, if any:
    /// `~/Applications/Papegøye.app/Contents/MacOS/parrot` → `…/Papegøye.app`.
    ///
    /// Nil for a bare binary on `PATH`, which is still a perfectly good way to
    /// run parrot — it just doesn't keep its TCC grant across upgrades.
    static func enclosing(executable path: String) -> String? {
        let macOS = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return nil }
        let contents = macOS.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return app.path
    }
}

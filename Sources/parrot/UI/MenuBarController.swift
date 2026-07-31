import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let routeLabel: NSMenuItem
    private let modelID: String

    /// `buttonTitle` puts a short text label next to the bird icon — used by
    /// bilingual mode to show the active pair, e.g. "nb-small+en-small".
    init(modelID: String, buttonTitle: String? = nil) {
        self.modelID = modelID
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle · hold fn to dictate", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        routeLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        routeLabel.isEnabled = false
        routeLabel.isHidden = true
        menu.addItem(routeLabel)

        menu.addItem(.separator())

        // The command stays `parrot` — renaming it would break the LaunchAgent
        // label, the install path and every merge from upstream. This is the one
        // place a human reads the name rather than types it, so it gets the
        // fork's.
        let quit = NSMenuItem(
            title: "Quit Papegøye",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton(recording: false, title: buttonTitle)
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : "idle · hold fn to dictate"
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    /// Show the last routing decision (bilingual mode), e.g. "no→no 0.94 · 12ms".
    func setLastDecision(_ text: String) {
        routeLabel.title = "last route: \(text)"
        routeLabel.isHidden = false
    }

    private func configureButton(recording: Bool, title: String? = nil) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
        if let title {
            button.title = " \(title)"
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

import AppKit
import ZIrisCore

// The menubar item (menubar.py): a template icon (◌ beside it while paused),
// the config's state, one status line per server, Pause, Reload config, Open
// config file and Quit. The rules editor arrives with the SwiftUI window.

private let pausedTitle = "◌"
private let activeTitle = "◉"

/// Whether delivery is paused; read by the engine from any thread.
public final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    public init() {}

    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }
}

@MainActor
public final class MenuBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: Settings
    private let pause: PauseFlag
    private let hasIcon: Bool
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private var serverItems: [String: NSMenuItem] = [:]
    private var timer: Timer?

    /// - Parameter icon: the template image's path, or nil for the text title.
    public init(settings: Settings, pause: PauseFlag, icon: String?) {
        self.settings = settings
        self.pause = pause
        let image = icon.flatMap { NSImage(contentsOfFile: $0) }
        image?.isTemplate = true
        image?.size = NSSize(width: 20, height: 20)
        hasIcon = image != nil
        super.init()
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(errorItem)
        for server in settings.config.servers {
            let line = NSMenuItem(title: "\(server.name): connecting", action: nil, keyEquivalent: "")
            serverItems[server.name] = line
            menu.addItem(line)
        }
        menu.addItem(.separator())
        for entry in [pauseItem,
                      NSMenuItem(title: "Reload config", action: #selector(reloadConfig), keyEquivalent: ""),
                      NSMenuItem(title: "Open config file", action: #selector(openConfig), keyEquivalent: "")] {
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit z-iris", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        showPauseState()
        showConfigError(settings.error)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showConfigError(self?.settings.reload()) }
        }
    }

    public func status(_ server: String, _ text: String) {
        serverItems[server]?.title = "\(server): \(text)"
    }

    @objc private func togglePause() {
        pause.isPaused.toggle()
        pauseItem.title = pause.isPaused ? "Resume" : "Pause"
        showPauseState()
    }

    private func showPauseState() {
        let paused = pause.isPaused
        item.button?.title = hasIcon ? (paused ? pausedTitle : "") : (paused ? pausedTitle : activeTitle)
    }

    private func showConfigError(_ error: String?) {
        errorItem.title = error.map { "Config problem: \($0.prefix(80))" } ?? "Config OK"
    }

    @objc private func reloadConfig() {
        showConfigError(settings.reload(force: true))
    }

    @objc private func openConfig() {
        if let path = settings.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}

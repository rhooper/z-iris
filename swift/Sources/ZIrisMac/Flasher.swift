import AppKit
import ZIrisCore

// Screen flash: a click-through overlay on every screen that fades out at
// 60 Hz (visual.py's Flasher and MacBackend).

/// An NSWindow that refuses to be nudged out from under the menu bar.
private final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class Flasher {
    private var windows: [NSWindow] = []
    private var generation = 0
    private var timer: Timer?

    public init() {}

    /// Safe from any thread: the work runs on the main actor.
    public nonisolated func flash(mode: String, color: String, seconds: Double) {
        Task { @MainActor in self.show(mode: mode, color: color, seconds: seconds) }
    }

    public func show(mode: String, color: String, seconds: Double) {
        closeAll()
        generation += 1
        let current = generation
        let rgb = parseColor(color)
        let alpha = startAlpha(mode: mode)
        for screen in NSScreen.screens {
            let f = screen.frame
            for rect in flashFrames(FlashRect(f.origin.x, f.origin.y, f.width, f.height), mode: mode) {
                windows.append(open(rect, rgb, alpha))
            }
        }
        guard !windows.isEmpty else { return }
        let started = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let keep = MainActor.assumeIsolated {
                self?.tick(current, started: started, alpha: alpha, seconds: seconds) ?? false
            }
            if !keep { timer.invalidate() }
        }
    }

    private func tick(_ current: Int, started: Double, alpha: Double, seconds: Double) -> Bool {
        guard current == generation else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if elapsed >= seconds {
            closeAll()
            return false
        }
        let level = fadeAlpha(start: alpha, elapsed: elapsed, duration: seconds)
        for window in windows { window.alphaValue = level }
        return true
    }

    private func open(_ rect: FlashRect, _ rgb: (red: Double, green: Double, blue: Double), _ alpha: Double) -> NSWindow {
        let window = OverlayWindow(
            contentRect: NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.alphaValue = alpha
        window.orderFrontRegardless()  // no activation: the app never becomes key
        return window
    }

    private func closeAll() {
        timer?.invalidate()
        timer = nil
        let closing = windows
        windows = []
        for window in closing {
            window.orderOut(nil)
            window.close()
        }
    }
}

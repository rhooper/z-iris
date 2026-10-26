// Spike (Swift port, phase 3a), 2026-10-26: does an app nested in
// Contents/Helpers get its own notification identity and Alerts style?
// One source for both bundles: the outer app posts a notification and opens
// the nested helper, which posts one too. Both log what macOS reports to
// ~/Library/Logs/z-iris-spike.log. Build and install with
// scripts/claude/spikes/build_helper_identity.sh.

import AppKit
import UserNotifications

let bundleID = Bundle.main.bundleIdentifier ?? "?"
let isHelper = bundleID.hasSuffix(".helper")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/z-iris-spike.log")

func log(_ text: String) {
    let line = "\(Date()) \(bundleID): \(text)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        log("launched from \(Bundle.main.bundlePath)")
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("authorization granted=\(granted) error=\(String(describing: error))")
            center.getNotificationSettings { settings in
                let style = ["none", "banner", "alert"][min(Int(settings.alertStyle.rawValue), 2)]
                log("settings authorization=\(settings.authorizationStatus.rawValue) alertStyle=\(style)")
                let content = UNMutableNotificationContent()
                content.title = isHelper ? "z-iris spike: helper" : "z-iris spike: main app"
                content.body = isHelper ? "Should stay until dismissed (Alerts)." : "A normal banner."
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                    log("posted error=\(String(describing: error))")
                }
            }
        }
        if !isHelper {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/z-iris-spike-helper.app")
            NSWorkspace.shared.openApplication(at: helper, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                log("opened helper pid=\(app?.processIdentifier ?? -1) error=\(String(describing: error))")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound, .list])
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

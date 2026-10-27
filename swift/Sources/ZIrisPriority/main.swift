import AppKit
import UserNotifications
import ZIrisMac

// z-iris priority: z-iris runs this as a child and writes one JSON request
// per line on stdin; each gets one JSON reply line on stdout (priority.py's
// main). macOS also launches it alone to deliver a click on an alert; it
// quits 30 seconds after z-iris goes away or the click is handled. The top
// level stays synchronous (see the app's main.swift).

let idleExit = 30.0

final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime
    func touch() { lock.withLock { last = ProcessInfo.processInfo.systemUptime } }
    var idle: Double { lock.withLock { ProcessInfo.processInfo.systemUptime - last } }
}

final class Clicks: NSObject, UNUserNotificationCenterDelegate {
    let service: PriorityService
    let activity: Activity

    init(service: PriorityService, activity: Activity) {
        self.service = service
        self.activity = activity
    }

    // Per-notification callbacks are lost when a click relaunches the app;
    // the delegate always gets the identifier.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        activity.touch()
        service.clicked(response.notification.request.identifier)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list] }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let activity = Activity()
let service = PriorityService()
let clicks = Clicks(service: service, activity: activity)
UNUserNotificationCenter.current().delegate = clicks

Thread.detachNewThread {
    let done = DispatchSemaphore(value: 0)
    while let line = readLine(strippingNewline: true) {
        activity.touch()
        if line.allSatisfy(\.isWhitespace) { continue }
        Task {
            let reply = await priorityReply(line, service)
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            done.signal()
        }
        done.wait()  // one request at a time, replies in order
    }
    // z-iris has gone, or macOS launched this app only to deliver a click.
    activity.touch()
    while activity.idle < idleExit {
        Thread.sleep(forTimeInterval: 1)
    }
    DispatchQueue.main.async { app.terminate(nil) }
}
withExtendedLifetime(clicks) { app.run() }

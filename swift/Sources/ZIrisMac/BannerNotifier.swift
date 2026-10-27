import AppKit
import UserNotifications
import ZIrisCore

// Banners through UNUserNotificationCenter (notify.py). The permission is
// asked once and checked again every few minutes; while the first prompt is
// unanswered a banner waits a bounded time. Clicks open the conversation,
// also after a restart: URLs are kept on disk by notification id. Changes
// between working and refused are logged once each, not per banner.

public protocol Notifying: Sendable {
    /// thread: macOS stacks alerts with the same thread together.
    func show(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?,
              thread: String?) async
    func clear(_ group: String) async
}

extension Notifying {
    public func show(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?) async {
        await show(title: title, body: body, url: url, image: image, group: group, sender: sender, thread: nil)
    }
}

public func openURL(_ url: String) {
    guard let target = URL(string: url) else { return }
    DispatchQueue.main.async { NSWorkspace.shared.open(target) }
}

public final class BannerNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let urls: URLStore
    private let opener: @Sendable (String) -> Void
    private let entitled: Bool
    private let authorizationTimeout: Double
    private let recheck: Double
    private let lock = NSLock()
    private var authorized: Bool?
    private var checked: Double?
    private var asking: Task<Bool, Never>?
    private var state: String?
    private var commsWarned = false

    public init(
        urls: URLStore, opener: @escaping @Sendable (String) -> Void = openURL,
        center: UNUserNotificationCenter = .current(), entitled: Bool = hasCommunicationEntitlement,
        authorizationTimeout: Double = 10, recheck: Double = 300
    ) {
        self.center = center
        self.urls = urls
        self.opener = opener
        self.entitled = entitled
        self.authorizationTimeout = authorizationTimeout
        self.recheck = recheck
        super.init()
        // Clicks on banners from before a restart, or a click that launched
        // the app, reach only the delegate, which must be set first.
        center.delegate = self
    }

    private func transition(_ next: String, _ text: String) {
        let changed = lock.withLock { () -> Bool in
            defer { state = next }
            return state != next
        }
        if changed { logProblem(text) }
    }

    /// Whether a banner may be sent. The first prompt is waited for at most
    /// authorizationTimeout seconds.
    private func ready() async -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let task = lock.withLock { () -> Task<Bool, Never> in
            let stale = checked.map { now - $0 >= recheck } ?? true
            if let asking, !(stale && authorized != nil) {
                return asking
            }
            let fresh = Task { [center] () -> Bool in
                (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            asking = fresh
            authorized = nil
            return fresh
        }
        let answer = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask { [authorizationTimeout] in
                try? await Task.sleep(for: .seconds(authorizationTimeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer else {
            transition("waiting", "waiting for the notification permission prompt; banners are not shown meanwhile")
            return false
        }
        lock.withLock {
            authorized = answer
            checked = ProcessInfo.processInfo.systemUptime
        }
        if !answer {
            transition("refused", "notifications not allowed for z-iris. Allow them in System Settings, Notifications, z-iris")
        }
        return answer
    }

    public func show(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?,
                     thread: String?) async {
        guard await ready() else { return }
        let identifier = group ?? UUID().uuidString
        urls.put(identifier, url)
        if let sender, await sendFrom(sender, identifier: identifier, title: title, body: body) {
            transition("native", "banners working")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil  // z-iris plays the sound
        if let thread {
            content.threadIdentifier = thread
        }
        if let picture = attachment(image) {
            content.attachments = [picture]
        }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            transition("native", "banners working")
        } catch {
            lock.withLock { checked = nil }  // look at the permission again next time
            transition("failed", "macOS refused the notification (\(error.localizedDescription))")
        }
    }

    /// The sender's face as the icon. False (with one warning) when macOS
    /// cannot: the caller then sends the plain banner.
    private func sendFrom(_ sender: Sender, identifier: String, title: String, body: String) async -> Bool {
        let warn = { (text: String) in
            let first = self.lock.withLock { () -> Bool in
                defer { self.commsWarned = true }
                return !self.commsWarned
            }
            if first { logProblem(text) }
        }
        guard entitled else {
            warn("sender icons need the communication entitlement (build with Z_IRIS_PROFILE); plain banners")
            return false
        }
        do {
            let picture = sender.groupName == nil ? nil : groupPicture(sender)
            try await sendCommunication(identifier: identifier, title: title, body: body, sender: sender,
                                        urgency: .active, groupImage: picture, center: center)
            return true
        } catch {
            warn("sender icons unavailable (\(error)); plain banners")
            return false
        }
    }

    public func clear(_ group: String) async {
        guard await ready() else { return }
        center.removeDeliveredNotifications(withIdentifiers: [group])
        urls.drop([group])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if let url = urls.pop(response.notification.request.identifier) {
            opener(url)
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

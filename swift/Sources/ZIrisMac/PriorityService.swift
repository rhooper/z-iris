import Foundation
import UserNotifications
import ZIrisCore

// z-iris priority: the second app, which shows sticky alerts (priority.py).
// macOS sets banner or alert style once per app, so persistent alerts come
// from this app while z-iris keeps its banners. z-iris runs it as a child and
// writes one JSON request per line; each gets one JSON reply line.

public let priorityURLs = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/z-iris/priority-urls.json")

/// What the service needs from UNUserNotificationCenter.
public protocol AlertCenter: Sendable {
    /// "allowed", "denied" or "undetermined", without ever prompting.
    func authorization() async -> String
    /// "alert", "banner" or "none".
    func alertStyle() async -> String
    func requestAuthorization() async
    /// A time-sensitive alert without sound (z-iris plays it).
    func add(identifier: String, title: String, body: String, attachment: String?, thread: String?) async throws
    func delivered() async -> [String]
    func remove(_ identifiers: [String]) async
}

/// The real notification center (always the shared one, which is thread safe).
public struct UserNotificationAlerts: AlertCenter {
    private var center: UNUserNotificationCenter { .current() }

    public init() {}

    public func authorization() async -> String {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: "undetermined"
        case .denied: "denied"
        default: "allowed"
        }
    }

    public func alertStyle() async -> String {
        switch await center.notificationSettings().alertStyle {
        case .alert: "alert"
        case .banner: "banner"
        default: "none"
        }
    }

    public func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func add(identifier: String, title: String, body: String, attachment path: String?, thread: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let thread {
            content.threadIdentifier = thread
        }
        // Time-sensitive needs an entitlement; without it macOS delivers an
        // ordinary alert, so asking is always safe.
        content.interruptionLevel = .timeSensitive
        if let item = attachment(path) {
            content.attachments = [item]
        }
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    public func delivered() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    public func remove(_ identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Sends a communication alert from a sender; throws CommsError to fall back.
public typealias SendCommunication = @Sendable (_ identifier: String, _ title: String, _ body: String,
                                                _ sender: Sender, _ groupImage: String?) async throws -> Void

private func bad(_ reason: String) -> [String: Any] {
    ["ok": false, "reason": reason]
}

/// Answers z-iris's requests. Never throws: a bad request gets ok false.
public final class PriorityService: @unchecked Sendable {
    private let center: any AlertCenter
    private let urls: URLStore
    private let opener: @Sendable (String) -> Void
    private let comms: SendCommunication
    private let entitled: Bool
    private let pictures: URL
    private let lock = NSLock()
    private var prompt: Task<Void, Never>?

    public init(
        center: any AlertCenter = UserNotificationAlerts(), urls: URLStore = URLStore(url: priorityURLs),
        opener: @escaping @Sendable (String) -> Void = openURL,
        comms: @escaping SendCommunication = { id, title, body, sender, picture in
            try await sendCommunication(identifier: id, title: title, body: body, sender: sender,
                                        urgency: .timeSensitive, groupImage: picture)
        },
        entitled: Bool = hasCommunicationEntitlement, pictures: URL = groupPictures
    ) {
        self.center = center
        self.urls = urls
        self.opener = opener
        self.comms = comms
        self.entitled = entitled
        self.pictures = pictures
    }

    public func handle(_ request: Any) async -> [String: Any] {
        guard let request = request as? [String: Any] else { return bad("request must be an object") }
        switch request["op"] as? String {
        case "status":
            // Never the prompt: it waits for the user, and z-iris would take
            // the silence for a hang.
            return ["ok": true, "allowed": await center.authorization() == "allowed", "style": await center.alertStyle()]
        case "show":
            return await show(request)
        case "clear":
            guard let groups = request["groups"] as? [Any], let names = groups as? [String], names.count == groups.count else {
                return bad("groups must be a list of strings")
            }
            await clear(names)
            return ["ok": true]
        case "clear_server":
            return await clearServer(request)
        default:
            return bad("unknown op \(pythonRepr(request["op"]))")
        }
    }

    private func show(_ request: [String: Any]) async -> [String: Any] {
        guard let title = request["title"] as? String, let body = request["body"] as? String,
              let url = request["url"] as? String, let group = request["group"] as? String
        else { return bad("show needs title, body, url and group strings") }
        let status = await center.authorization()
        if status == "undetermined" {
            // Ask in the background; z-iris shows a banner until it is answered.
            lock.withLock {
                if prompt == nil { prompt = Task { [center] in await center.requestAuthorization() } }
            }
            return bad("waiting for permission")
        }
        guard status == "allowed" else { return bad("not allowed") }
        let image = (request["image"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        urls.put(group, url)
        var plain: String?
        let sender = request["sender"].flatMap(Sender.init(json:))
        if let sender, !entitled {
            plain = "sender icons need the communication entitlement"
        } else if let sender {
            do {
                try await comms(group, title, body, sender, sender.groupName == nil ? nil : groupPicture(sender, in: pictures))
                return ["ok": true]
            } catch {
                plain = "\(error)"  // z-iris warns once; the alert still goes out
            }
        }
        // A plain alert shows the sender's avatar as before.
        let attachment = image ?? sender?.avatar.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        do {
            try await center.add(identifier: group, title: title, body: body, attachment: attachment,
                                 thread: request["thread"] as? String)
        } catch {
            return bad(error.localizedDescription)
        }
        return plain.map { ["ok": true, "plain": $0] } ?? ["ok": true]
    }

    private func clear(_ groups: [String]) async {
        // Only what is on screen: a bulk read can name thousands of groups.
        let delivered = Set(await center.delivered())
        let onScreen = groups.filter(delivered.contains)
        if !onScreen.isEmpty {
            await center.remove(onScreen)
        }
        urls.drop(groups)
    }

    private func clearServer(_ request: [String: Any]) async -> [String: Any] {
        guard let server = request["server"] as? String, let keep = request["keep"] as? [Any],
              keep.allSatisfy({ jsonInt($0) != nil })
        else { return bad("clear_server needs a server string and a list of ids") }
        let kept = Set(keep.compactMap(jsonInt))
        let prefix = "z-iris-\(server)-"
        // Conversation summaries z-iris no longer tracks (it restarted, or
        // the topic was read) go too; older z-iris sends no keep_groups.
        let summaries = "z-iris-conversation-\(server)-"
        let keptGroups = Set((request["keep_groups"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let doomed = await center.delivered().filter { identifier in
            if identifier.hasPrefix(summaries) { return !keptGroups.contains(identifier) }
            guard identifier.hasPrefix(prefix) else { return false }
            let digits = identifier.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(digits) else { return false }
            return !kept.contains(id)
        }
        await clear(doomed)
        return ["ok": true]
    }

    public func clicked(_ group: String) {
        if let url = urls.pop(group) {
            opener(url)
        }
    }
}

/// One reply line for one request line ("bad json" for anything unreadable).
public func priorityReply(_ line: String, _ service: PriorityService) async -> String {
    let reply: [String: Any]
    if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) {
        reply = await service.handle(object)
    } else {
        reply = bad("bad json")
    }
    let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"ok": false, "reason": "reply"}"#.utf8)
    return String(decoding: data, as: UTF8.self)
}

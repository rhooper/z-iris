import Foundation

// Reactions to your messages: someone else adding an emoji to a message you
// wrote. A burst on one message is one alert, updated in place.

public struct ReactionEvent: Sendable, Equatable {
    public var messageID: Int
    public var userID: Int
    public var userName: String
    public var emojiName: String
    /// The emoji itself, or ":name:" for a custom one.
    public var emoji: String
    public var added: Bool

    public init(messageID: Int, userID: Int, userName: String, emojiName: String, emoji: String, added: Bool) {
        self.messageID = messageID
        self.userID = userID
        self.userName = userName
        self.emojiName = emojiName
        self.emoji = emoji
        self.added = added
    }

    /// A reaction event's meaning, or nil for any other event.
    public init?(_ event: [String: Any]) {
        guard event["type"] as? String == "reaction",
              let messageID = event["message_id"].flatMap(jsonInt),
              let name = event["emoji_name"] as? String
        else { return nil }
        let user = event["user"] as? [String: Any]
        // Newer servers send only user_id; older ones only the user object.
        guard let userID = event["user_id"].flatMap(jsonInt) ?? user?["user_id"].flatMap(jsonInt) else { return nil }
        var emoji = ":\(name):"
        if event["reaction_type"] as? String == "unicode_emoji", let code = event["emoji_code"] as? String {
            let scalars = code.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            if !scalars.isEmpty {
                emoji = String(String.UnicodeScalarView(scalars))
            }
        }
        self.init(messageID: messageID, userID: userID, userName: user?["full_name"] as? String ?? "Someone",
                  emojiName: name, emoji: emoji, added: event["op"] as? String == "add")
    }
}

/// Reactions to each message in the last minute.
final class ReactionBursts: @unchecked Sendable {
    static let window = 60.0

    struct Burst {
        var last: Date
        var names: [String] = []
        var emojis: [String] = []
    }

    private let lock = NSLock()
    private var bursts: [Int: Burst] = [:]

    func add(messageID: Int, name: String, emoji: String, now: Date) -> Burst {
        lock.withLock {
            bursts = bursts.filter { now.timeIntervalSince($0.value.last) < Self.window }
            var burst = bursts[messageID] ?? Burst(last: now)
            burst.last = now
            if !burst.names.contains(name) { burst.names.append(name) }
            if !burst.emojis.contains(emoji) { burst.emojis.append(emoji) }
            bursts[messageID] = burst
            return burst
        }
    }
}

extension Pipeline {
    /// A notification for someone else's reaction to one of your messages.
    public func handleReaction(_ event: ReactionEvent, now: Date) -> Notification? {
        let config = config()
        guard config.reactions, event.added, event.userID != selfID,
              let own = conversations?.own(event.messageID)
        else { return nil }
        let place = ReactionPlace(server: server, channelName: own.channelName, topic: own.topic, isDM: own.kind == .dm)
        let picked = pickReactionRule(config.rules, place: place, emoji: event.emojiName)
        let action = resolveAction(config, server: server, rule: picked?.parent, layer: picked?.rule,
                                   layerBuiltIns: reactionBuiltIns, layerSound: "none")
        let burst = bursts.add(messageID: own.id, name: event.userName, emoji: event.emoji, now: now)
        let who = switch burst.names.count {
        case 1: burst.names[0]
        case 2: "\(burst.names[0]) and \(burst.names[1])"
        default: "\(burst.names[0]) and \(burst.names.count - 1) others"
        }
        let whereText = own.kind == .dm ? "in a direct message" : "in #\(own.channelName ?? "") > \(own.topic ?? "")"
        let message = Message(
            server: server, host: host, id: own.id, kind: own.kind, senderID: event.userID, senderName: event.userName,
            content: own.snippet, flags: [], channelID: own.place?.channelID, channelName: own.channelName,
            topic: own.topic, dmUserIDs: own.dmUserIDs
        )
        var notification = Notification(
            message: message, url: narrowURL(message), reason: "reaction", action: action,
            summary: "\(who) reacted \(burst.emojis.joined()) to your message \(whereText)"
        )
        notification.group = "z-iris-reaction-\(server)-\(own.id)"
        return notification
    }
}

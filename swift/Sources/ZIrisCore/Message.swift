import Foundation

/// A Zulip message event, reduced to the fields z-iris needs.
public struct Message: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case channel, dm
    }

    public var server: String
    public var host: String
    public var id: Int
    public var kind: Kind
    public var senderID: Int
    public var senderName: String
    public var content: String
    public var flags: Set<String>
    public var channelID: Int?
    public var channelName: String?
    public var topic: String?
    /// Everyone but me, sorted; just me for a self-DM.
    public var dmUserIDs: [Int]
    /// The sender's avatar as the server gave it.
    public var avatarURL: String?
    /// Full names in dmUserIDs order; "" if unknown.
    public var dmNames: [String]

    public init(
        server: String, host: String, id: Int, kind: Kind, senderID: Int,
        senderName: String, content: String, flags: Set<String>, channelID: Int?,
        channelName: String?, topic: String?, dmUserIDs: [Int],
        avatarURL: String? = nil, dmNames: [String] = []
    ) {
        self.server = server
        self.host = host
        self.id = id
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.content = content
        self.flags = flags
        self.channelID = channelID
        self.channelName = channelName
        self.topic = topic
        self.dmUserIDs = dmUserIDs
        self.avatarURL = avatarURL
        self.dmNames = dmNames
    }

    public var isMention: Bool { flags.contains("mentioned") }

    // Servers send the new per-kind flags and, for older clients, the first.
    public var isWildcardMention: Bool { !flags.isDisjoint(with: Self.wildcardFlags) }

    public var hasAlertWord: Bool { flags.contains("has_alert_word") }

    private static let wildcardFlags: Set<String> = [
        "wildcard_mentioned", "stream_wildcard_mentioned", "topic_wildcard_mentioned",
    ]
}

public struct MalformedEvent: Error, Equatable {
    public var reason: String
}

extension Message {
    /// Build a Message from a decoded JSON event (JSONSerialization types).
    /// Throws MalformedEvent where Python raises KeyError or TypeError.
    public init(server: String, host: String, selfID: Int, event: [String: Any]) throws {
        guard let raw = event["message"] as? [String: Any] else {
            throw MalformedEvent(reason: "message")
        }
        let flags: Set<String>
        switch event["flags"] {
        case nil: flags = []
        case let list as [String]: flags = Set(list)
        default: throw MalformedEvent(reason: "flags")
        }
        let id = try raw.int("id")
        let senderID = try raw.int("sender_id")
        let senderName = try raw.string("sender_full_name")
        let content = try raw.string("content")
        let avatarURL = raw["avatar_url"] as? String
        let type = try raw.string("type")

        if type == "stream" {
            let topic = try raw.string(raw["subject"] != nil ? "subject" : "topic")
            self.init(
                server: server, host: host, id: id, kind: .channel, senderID: senderID,
                senderName: senderName, content: content, flags: flags,
                channelID: try raw.int("stream_id"),
                channelName: try raw.string("display_recipient"),
                topic: topic, dmUserIDs: [], avatarURL: avatarURL
            )
            return
        }

        guard let people = raw["display_recipient"] as? [[String: Any]] else {
            throw MalformedEvent(reason: "display_recipient")
        }
        var names: [Int: String] = [:]
        for person in people {
            names[try person.int("id")] = person["full_name"] as? String ?? ""
        }
        let others = names.keys.filter { $0 != selfID }.sorted()
        let ids = others.isEmpty ? [selfID] : others
        self.init(
            server: server, host: host, id: id, kind: .dm, senderID: senderID,
            senderName: senderName, content: content, flags: flags,
            channelID: nil, channelName: nil, topic: nil, dmUserIDs: ids,
            avatarURL: avatarURL, dmNames: ids.map { names[$0] ?? "" }
        )
    }
}

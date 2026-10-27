import Foundation

// Conversations you are in: channel topics you posted in (or were mentioned
// in), joined until they have been quiet for joined_hours, and your own
// recent messages, so a reaction can be traced to one of them. Joined topics
// are kept on disk across restarts.

/// A channel topic. Topics compare as Zulip compares them: case-insensitively.
public struct TopicKey: Hashable, Codable, Sendable {
    public let server: String
    public let channelID: Int
    public let topic: String

    public init(server: String, channelID: Int, topic: String) {
        self.server = server
        self.channelID = channelID
        self.topic = topic.pythonLowercased
    }

    private enum CodingKeys: String, CodingKey {
        case server, channelID = "channel_id", topic
    }
}

public struct OwnMessage: Sendable, Equatable {
    public var id: Int
    public var kind: Message.Kind
    /// Where it is, for channel messages.
    public var place: TopicKey?
    /// The start of its text, for a reaction's banner.
    public var snippet: String

    public init(id: Int, kind: Message.Kind, place: TopicKey?, snippet: String) {
        self.id = id
        self.kind = kind
        self.place = place
        self.snippet = snippet
    }
}

public final class Conversations: @unchecked Sendable {
    public static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/z-iris/joined.json")
    static let ownLimit = 500

    private struct Entry: Codable {
        var key: TopicKey
        var lastActivity: Date

        private enum CodingKeys: String, CodingKey {
            case server, channelID = "channel_id", topic, lastActivity = "last_activity"
        }

        init(key: TopicKey, lastActivity: Date) {
            self.key = key
            self.lastActivity = lastActivity
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            key = TopicKey(server: try values.decode(String.self, forKey: .server),
                           channelID: try values.decode(Int.self, forKey: .channelID),
                           topic: try values.decode(String.self, forKey: .topic))
            lastActivity = try values.decode(Date.self, forKey: .lastActivity)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(key.server, forKey: .server)
            try values.encode(key.channelID, forKey: .channelID)
            try values.encode(key.topic, forKey: .topic)
            try values.encode(lastActivity, forKey: .lastActivity)
        }
    }

    private let file: URL?
    private let hours: @Sendable () -> Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var joined: [TopicKey: Date] = [:]
    private var own: [Int: OwnMessage] = [:]
    private var ownOrder: [Int] = []

    /// - Parameter hours: how long a quiet topic stays joined (read each time).
    public init(file: URL?, hours: @escaping @Sendable () -> Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.hours = hours
        self.now = now
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            for entry in (try? decoder.decode([Entry].self, from: data)) ?? [] {
                joined[entry.key] = entry.lastActivity
            }
        }
    }

    private func expired(_ last: Date) -> Bool {
        now().timeIntervalSince(last) >= Double(hours()) * 3600
    }

    public func join(_ key: TopicKey) {
        lock.withLock { joined[key] = now() }
        save()
    }

    /// Record activity in a joined topic; never joins.
    public func touch(_ key: TopicKey) {
        let changed = lock.withLock { () -> Bool in
            guard let last = joined[key], !expired(last) else { return false }
            joined[key] = now()
            return true
        }
        if changed { save() }
    }

    public func isJoined(_ key: TopicKey) -> Bool {
        let (result, forgot) = lock.withLock { () -> (Bool, Bool) in
            guard let last = joined[key] else { return (false, false) }
            if expired(last) {
                joined[key] = nil
                return (false, true)
            }
            return (true, false)
        }
        if forgot { save() }
        return result
    }

    /// One of your messages moved (a topic renamed, or moved to another
    /// channel): a joined topic follows it.
    public func move(messageID: Int, to key: TopicKey) {
        lock.withLock {
            guard var message = own[messageID] else { return }
            if let old = message.place, let last = joined.removeValue(forKey: old) {
                joined[key] = last
            }
            message.place = key
            own[messageID] = message
        }
        save()
    }

    public func recordOwn(_ message: OwnMessage) {
        lock.withLock {
            if own[message.id] == nil { ownOrder.append(message.id) }
            own[message.id] = message
            while ownOrder.count > Self.ownLimit {
                own[ownOrder.removeFirst()] = nil
            }
        }
    }

    public func own(_ id: Int) -> OwnMessage? {
        lock.withLock { own[id] }
    }

    private func save() {
        guard let file else { return }
        let entries = lock.withLock { joined.map { Entry(key: $0.key, lastActivity: $0.value) } }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

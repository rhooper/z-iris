/// Track which channels and topics the user has muted.
public struct MuteState: Sendable {
    private static let muted = 1, unmuted = 2, followed = 3

    private struct TopicKey: Hashable, Sendable {
        var channelID: Int
        var topic: String

        init(_ channelID: Int, _ topic: String) {
            self.channelID = channelID
            self.topic = topic.pythonLowercased
        }
    }

    private var mutedChannels: Set<Int> = []
    private var channelIDsByName: [String: Int] = [:]
    private var topicPolicy: [TopicKey: Int] = [:]
    // Topics that came from the legacy muted_topics list, so a new legacy list
    // can replace them without touching user_topic state.
    private var legacyTopics: Set<TopicKey> = []

    public init() {}

    public init(register response: [String: Any]) throws {
        for case let subscription as [String: Any] in response.list("subscriptions") {
            try addSubscription(subscription)
        }
        for case let entry as [String: Any] in response.list("user_topics") {
            try setPolicy(entry.int("stream_id"), entry.string("topic_name"), entry.int("visibility_policy"))
        }
        try setLegacyMutedTopics(response.list("muted_topics"))
    }

    public func isMuted(channelID: Int, topic: String) -> Bool {
        switch topicPolicy[TopicKey(channelID, topic)] {
        case Self.muted: true
        case Self.unmuted, Self.followed: false
        default: mutedChannels.contains(channelID)
        }
    }

    public mutating func apply(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "subscription":
            try applySubscription(event)
        case "user_topic":
            try setPolicy(event.int("stream_id"), event.string("topic_name"), event.int("visibility_policy"))
        case "muted_topics":
            try setLegacyMutedTopics(event.list("muted_topics"))
        default:
            break
        }
    }

    private mutating func addSubscription(_ subscription: [String: Any]) throws {
        let channelID = try subscription.int("stream_id")
        channelIDsByName[subscription["name"] as? String ?? ""] = channelID
        if subscription.truthy("is_muted") {
            mutedChannels.insert(channelID)
        } else {
            mutedChannels.remove(channelID)
        }
    }

    private mutating func applySubscription(_ event: [String: Any]) throws {
        switch event["op"] as? String {
        case "add":
            for case let subscription as [String: Any] in event.list("subscriptions") {
                try addSubscription(subscription)
            }
        case "remove":
            for case let subscription as [String: Any] in event.list("subscriptions") {
                mutedChannels.remove(try subscription.int("stream_id"))
            }
        case "update" where event["property"] as? String == "is_muted":
            guard event["value"] != nil else { throw MalformedEvent(reason: "value") }
            let channelID = try event.int("stream_id")
            if event.truthy("value") {
                mutedChannels.insert(channelID)
            } else {
                mutedChannels.remove(channelID)
            }
        default:
            break
        }
    }

    private mutating func setPolicy(_ channelID: Int, _ topic: String, _ policy: Int) {
        let key = TopicKey(channelID, topic)
        legacyTopics.remove(key)
        if policy == 0 {
            topicPolicy[key] = nil
        } else {
            topicPolicy[key] = policy
        }
    }

    private mutating func setLegacyMutedTopics(_ entries: [Any]) throws {
        for key in legacyTopics {
            topicPolicy[key] = nil
        }
        legacyTopics = []
        for entry in entries {
            guard let fields = entry as? [Any], fields.count >= 2,
                  let channelName = fields[0] as? String, let topic = fields[1] as? String
            else { throw MalformedEvent(reason: "muted_topics") }
            guard let channelID = channelIDsByName[channelName] else { continue }
            let key = TopicKey(channelID, topic)
            topicPolicy[key] = Self.muted
            legacyTopics.insert(key)
        }
    }
}

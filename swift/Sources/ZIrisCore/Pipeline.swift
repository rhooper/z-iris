import Foundation

// Turn raw Zulip events into notifications.

public struct Notification: Sendable, Equatable {
    public var message: Message
    public var url: String
    public var reason: String
    public var action: Action
    /// A batch summary's heading, e.g. "3 new in #ops".
    public var summary: String?
    /// A summary's held messages, for a written summary.
    public var batch: [Message] = []
    /// The joined topic, for a message in a conversation you are in.
    public var conversation: TopicKey?
    /// The banner's group when it is not the message's own (reactions).
    public var group: String?

    public init(message: Message, url: String, reason: String, action: Action, summary: String? = nil) {
        self.message = message
        self.url = url
        self.reason = reason
        self.action = action
        self.summary = summary
    }
}

/// What would happen to a message, and why. Used by dry runs and previews.
public struct Verdict: Sendable, Equatable {
    public var notification: Notification?
    public var why: String
    public var ruleIndex: Int?
}

public struct Pipeline: Sendable {
    public let server: String
    public let host: String
    public let selfID: Int
    public var mutes: MuteState
    /// The current config; it changes when the file is reloaded.
    public let config: @Sendable () -> Config
    /// The topics you are in; nil leaves conversations out entirely.
    public let conversations: Conversations?
    let bursts = ReactionBursts()

    public init(server: String, host: String, selfID: Int, mutes: MuteState,
                config: @escaping @Sendable () -> Config, conversations: Conversations? = nil) {
        self.server = server
        self.host = host
        self.selfID = selfID
        self.mutes = mutes
        self.config = config
        self.conversations = conversations
    }

    /// One of your messages, sent now or at `time`: kept so reactions to it
    /// can be traced, and a channel message joins its topic.
    public func recordOwn(_ message: Message, at time: Date? = nil) {
        guard let conversations else { return }
        let key = topicKey(message)
        conversations.recordOwn(OwnMessage(
            id: message.id, kind: message.kind, place: key, snippet: plainBody(message, limit: 80),
            channelName: message.channelName, topic: message.topic, dmUserIDs: message.dmUserIDs
        ))
        if let key {
            if let time { conversations.join(key, at: time) } else { conversations.join(key) }
        }
    }

    private func topicKey(_ message: Message) -> TopicKey? {
        guard message.kind == .channel, let channelID = message.channelID else { return nil }
        return TopicKey(server: server, channelID: channelID, topic: message.topic ?? "")
    }

    public mutating func handle(_ event: [String: Any]) -> Notification? {
        if event["type"] as? String != "message" {
            try? mutes.apply(event)
            return nil
        }
        guard let message = try? Message(server: server, host: host, selfID: selfID, event: event) else {
            return nil
        }
        guard let conversations else {
            return evaluate(message).notification
        }
        let key = topicKey(message)
        if message.senderID == selfID {
            recordOwn(message)
            return nil
        }
        let notification = evaluate(message).notification
        if let key, blocked(message, mutes: mutes, selfID: selfID) == nil {
            let config = config()
            if (message.isMention && config.joinOnMention) || pickRule(config.rules, message)?.join == true {
                conversations.join(key)
            } else {
                conversations.touch(key)
            }
        }
        return notification
    }

    public func evaluate(_ message: Message) -> Verdict {
        if let reason = blocked(message, mutes: mutes, selfID: selfID) {
            return Verdict(notification: nil, why: reason)
        }
        let config = config()
        // A personal mention keeps its own handling, as anywhere else.
        if !message.isMention, let key = topicKey(message), conversations?.isJoined(key) == true {
            return joined(message, key, config)
        }
        if let rule = pickRule(config.rules, message) {
            let action = resolveAction(config, server: server, rule: rule)
            let silent = action.banner == "off" && (action.sound == "none" || action.volume == 0)
            // A rule that silences a channel must not swallow a personal ping.
            if !silent {
                let notification = Notification(message: message, url: narrowURL(message), reason: "rule", action: action)
                return Verdict(notification: notification, why: "rule", ruleIndex: rule.index)
            }
            if !message.isMention {
                return Verdict(notification: nil, why: "silenced by rule", ruleIndex: rule.index)
            }
        }
        let decision = decide(message, mutes: mutes, selfID: selfID, notifyChannelMessages: config.notifyChannelMessages)
        guard decision.notify else {
            return Verdict(notification: nil, why: decision.reason)
        }
        let notification = Notification(
            message: message, url: narrowURL(message), reason: decision.reason,
            action: resolveAction(config, server: server, rule: nil)
        )
        return Verdict(notification: notification, why: decision.reason)
    }

    /// A message in a topic you are in: its own rule's action with the
    /// conversation layer on top. It always shows, even where the rule is silent.
    private func joined(_ message: Message, _ key: TopicKey, _ config: Config) -> Verdict {
        let rule = pickRule(config.rules, message)
        var action = resolveAction(config, server: server, rule: rule, layer: conversationRule(config.rules, message),
                                   layerBuiltIns: conversationBuiltIns)
        if action.banner == "off" {
            action.banner = "full"
        }
        var notification = Notification(message: message, url: narrowURL(message), reason: "conversation", action: action)
        notification.conversation = key
        return Verdict(notification: notification, why: "conversation", ruleIndex: rule?.index)
    }
}

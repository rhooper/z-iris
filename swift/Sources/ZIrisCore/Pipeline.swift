// Turn raw Zulip events into notifications.

public struct Notification: Sendable, Equatable {
    public var message: Message
    public var url: String
    public var reason: String
    public var action: Action
    /// A batch summary's heading, e.g. "3 new in #ops".
    public var summary: String?

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

    public init(server: String, host: String, selfID: Int, mutes: MuteState,
                config: @escaping @Sendable () -> Config) {
        self.server = server
        self.host = host
        self.selfID = selfID
        self.mutes = mutes
        self.config = config
    }

    public mutating func handle(_ event: [String: Any]) -> Notification? {
        if event["type"] as? String != "message" {
            try? mutes.apply(event)
            return nil
        }
        guard let message = try? Message(server: server, host: host, selfID: selfID, event: event) else {
            return nil
        }
        return evaluate(message).notification
    }

    public func evaluate(_ message: Message) -> Verdict {
        if let reason = blocked(message, mutes: mutes, selfID: selfID) {
            return Verdict(notification: nil, why: reason)
        }
        let config = config()
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
}

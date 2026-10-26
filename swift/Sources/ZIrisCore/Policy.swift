// Decide whether a message deserves a notification.

public struct Decision: Sendable, Equatable {
    public var notify: Bool
    public var reason: String

    public init(_ notify: Bool, _ reason: String) {
        self.notify = notify
        self.reason = reason
    }
}

/// Why a message must stay silent whatever any rule says, or nil.
public func blocked(_ message: Message, mutes: MuteState, selfID: Int) -> String? {
    if message.senderID == selfID {
        return "own message"
    }
    if message.kind == .channel,
       mutes.isMuted(channelID: message.channelID ?? 0, topic: message.topic ?? ""),
       !message.isMention {
        return "muted"
    }
    return nil
}

public func decide(
    _ message: Message, mutes: MuteState, selfID: Int, notifyChannelMessages: Bool
) -> Decision {
    if let reason = blocked(message, mutes: mutes, selfID: selfID) {
        return Decision(false, reason)
    }
    if message.kind == .dm {
        return Decision(true, "dm")
    }
    if message.isMention {
        return Decision(true, "mention")
    }
    if message.isWildcardMention {
        return Decision(true, "wildcard mention")
    }
    if message.hasAlertWord {
        return Decision(true, "alert word")
    }
    if notifyChannelMessages {
        return Decision(true, "channel")
    }
    return Decision(false, "channel messages not enabled")
}

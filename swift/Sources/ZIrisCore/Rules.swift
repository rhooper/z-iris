// Pick the rule that decides how a message sounds.

/// Rule kinds in tie-break order: on equal priority the earlier kind wins.
public enum RuleKind: String, CaseIterable, Sendable {
    case topic, keyword, mention, wildcard
    case alertWord = "alert_word"
    case channel
    case groupDM = "group_dm"
    case dm
    // New in the Swift version; after dm so the kinds above keep their rank.
    case conversation
    case reaction

    var rank: Int { Self.allCases.firstIndex(of: self)! }

    var label: String {
        switch self {
        case .topic: "Topic"
        case .keyword: "Keyword"
        case .mention: "Mention"
        case .wildcard: "Wildcard mention"
        case .alertWord: "Alert word"
        case .channel: "Channel"
        case .groupDM: "Group DM"
        case .dm: "Direct message"
        case .conversation: "Conversation you're in"
        case .reaction: "Reaction to your message"
        }
    }
}

/// Boxes a sub-rule, which a struct cannot hold directly.
final class ReactionSubRule: Sendable {
    let rule: Rule

    init(_ rule: Rule) {
        self.rule = rule
    }
}

public struct Rule: Sendable, Equatable {
    /// Optional; the label falls back to what the rule matches.
    public var description: String?
    public var kind: RuleKind
    /// Channel names or patterns, each matching the whole channel name.
    public var channels: [String]
    public var pattern: PyRegex?
    public var server: String?
    public var sound: String?
    public var volume: Int?
    public var banner: String?
    public var priority: Int
    public var index: Int
    public var enabled: Bool
    /// Per-rule overrides of the BEHAVIOUR settings.
    public var behaviour: Behaviour
    /// Matching messages join their topic (a per-rule setting; never inherited).
    public var join: Bool
    /// For reaction rules: only these emoji names (empty: any).
    public var emoji: [String]
    private var reaction: ReactionSubRule?
    private var channelPatterns: [PyRegex]

    /// The rule's [rule.reaction] sub-rule: reactions on your messages that
    /// this rule's place covers.
    public var reactionRule: Rule? {
        get { reaction?.rule }
        set { reaction = newValue.map(ReactionSubRule.init) }
    }

    public init(
        description: String?, kind: RuleKind, channels: [String], pattern: PyRegex?,
        server: String?, sound: String?, volume: Int?, banner: String?, priority: Int,
        index: Int, enabled: Bool = true, behaviour: Behaviour = [:],
        join: Bool = false, emoji: [String] = []
    ) throws(PyRegex.Error) {
        self.join = join
        self.emoji = emoji
        self.description = description
        self.kind = kind
        self.channels = channels
        self.pattern = pattern
        self.server = server
        self.sound = sound
        self.volume = volume
        self.banner = banner
        self.priority = priority
        self.index = index
        self.enabled = enabled
        self.behaviour = behaviour
        var patterns: [PyRegex] = []
        for channel in channels {
            patterns.append(try PyRegex(channel))
        }
        channelPatterns = patterns
    }

    public static func == (lhs: Rule, rhs: Rule) -> Bool {
        lhs.description == rhs.description && lhs.kind == rhs.kind && lhs.channels == rhs.channels
            && lhs.pattern == rhs.pattern && lhs.server == rhs.server && lhs.sound == rhs.sound
            && lhs.volume == rhs.volume && lhs.banner == rhs.banner && lhs.priority == rhs.priority
            && lhs.index == rhs.index && lhs.enabled == rhs.enabled
    }

    /// The description, else what the rule matches ("Channel #ops, #deploys").
    public var label: String {
        if let description, !description.isEmpty {
            return description
        }
        let where_ = channels.map { "#\($0)" }.joined(separator: ", ")
        switch kind {
        case .channel, .conversation where !channels.isEmpty:
            return "\(kind.label) \(where_)"
        case .topic, .keyword:
            guard let pattern else { return kind.label }
            let text = "\(kind.label) /\(pattern.source)/"
            return where_.isEmpty ? text : "\(text) in \(where_)"
        default:
            return kind.label
        }
    }

    func inChannels(_ channel: String?) -> Bool {
        channelPatterns.contains { $0.fullMatch(channel ?? "") }
    }

    func matches(_ message: Message) -> Bool {
        if let server, server != message.server {
            return false
        }
        switch kind {
        case .channel:
            return message.kind == .channel && inChannels(message.channelName)
        case .topic:
            guard message.kind == .channel else { return false }
            if !channels.isEmpty, !inChannels(message.channelName) {
                return false
            }
            return pattern?.search(message.topic ?? "") != nil
        case .keyword:
            return pattern?.search(message.content) != nil
        case .mention:
            return message.isMention
        case .wildcard:
            return message.isWildcardMention
        case .alertWord:
            return message.hasAlertWord
        case .dm:
            return message.kind == .dm && message.dmUserIDs.count == 1
        case .groupDM:
            return message.kind == .dm && message.dmUserIDs.count > 1
        case .conversation, .reaction:
            return false  // layers and reactions, never competing for a message
        }
    }
}

public func pickRule(_ rules: [Rule], _ message: Message) -> Rule? {
    rules.filter { $0.enabled && $0.matches(message) }
        .min { a, b in (-a.priority, a.kind.rank, a.index) < (-b.priority, b.kind.rank, b.index) }
}

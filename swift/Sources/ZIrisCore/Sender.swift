import Foundation

// Who a notification is from, for macOS communication notifications.
//
// macOS shows the sender's picture as the main icon. For one person it uses
// the sender's display name as the title, so `name` is today's whole title
// ("Ada (#ops > deploys)"). For a group it shows the sender's name and then
// the group's name, so a group is name "Ada" with groupName "group", which
// reads like "Ada (group)". See docs/sender-icons-spike.md.

public let groupName = "group"

/// A message's two images: the sender's avatar and its first own picture.
public struct MessageImages: Sendable, Equatable {
    public var avatar: String?
    public var picture: String?

    public init(avatar: String? = nil, picture: String? = nil) {
        self.avatar = avatar
        self.picture = picture
    }
}

public struct Sender: Sendable, Equatable {
    /// zulip:<server>:<user id>
    public var handle: String
    /// What macOS shows as the sender.
    public var name: String
    public var avatar: String?
    /// The message's own image, the thumbnail.
    public var picture: String?
    public var conversation: String
    /// Set for group DMs only.
    public var groupName: String?
    /// (handle, name) of a group's people.
    public var members: [Member] = []

    public struct Member: Sendable, Equatable {
        public var handle: String
        public var name: String

        public init(handle: String, name: String) {
            self.handle = handle
            self.name = name
        }
    }

    public func toJSON() -> [String: Any] {
        [
            "handle": handle, "name": name, "avatar": avatar as Any? ?? NSNull(),
            "picture": picture as Any? ?? NSNull(), "conversation": conversation,
            "group_name": groupName as Any? ?? NSNull(),
            "members": members.map { [$0.handle, $0.name] },
        ]
    }

    /// The Sender, or nil for anything malformed.
    public init?(json data: Any) {
        guard let data = data as? [String: Any],
              let handle = data["handle"] as? String, let name = data["name"] as? String,
              let conversation = data["conversation"] as? String
        else { return nil }
        var members: [Member] = []
        switch data["members"] {
        case nil, is NSNull: break
        case let list as [Any]:
            for entry in list {
                guard let pair = entry as? [Any], pair.count == 2,
                      let memberHandle = pair[0] as? String, let memberName = pair[1] as? String
                else { return nil }
                members.append(Member(handle: memberHandle, name: memberName))
            }
        default:
            // Python's `data.get("members") or []` lets any falsy value through.
            guard !data.truthy("members") else { return nil }
        }
        var paths: [String?] = []
        for key in ["avatar", "picture"] {
            switch data[key] {
            case nil, is NSNull: paths.append(nil)
            case let text as String: paths.append(text.isEmpty ? nil : pythonPath(text, expandUser: false))
            default: return nil
            }
        }
        let group: String?
        switch data["group_name"] {
        case nil, is NSNull: group = nil
        case let text as String: group = text
        default: return nil
        }
        self.init(handle: handle, name: name, avatar: paths[0], picture: paths[1],
                  conversation: conversation, groupName: group, members: members)
    }

    public init(handle: String, name: String, avatar: String?, picture: String?,
                conversation: String, groupName: String? = nil, members: [Member] = []) {
        self.handle = handle
        self.name = name
        self.avatar = avatar
        self.picture = picture
        self.conversation = conversation
        self.groupName = groupName
        self.members = members
    }
}

private func handle(_ message: Message, _ userID: Int) -> String {
    "zulip:\(message.server):\(userID)"
}

/// The sender for a message's notification. nil when there is no face to
/// show (a one-to-one message without an avatar): the plain notification.
public func senderFor(_ message: Message, title: String, images: MessageImages) -> Sender? {
    let senderHandle = handle(message, message.senderID)
    let dmConversation = "\(message.server):dm:" + message.dmUserIDs.map(String.init).joined(separator: ",")
    if message.kind == .dm, message.dmUserIDs.count > 1 {
        let names = message.dmNames.isEmpty ? Array(repeating: "", count: message.dmUserIDs.count) : message.dmNames
        let members = zip(message.dmUserIDs, names).map { Sender.Member(handle: handle(message, $0), name: $1) }
        return Sender(handle: senderHandle, name: message.senderName, avatar: images.avatar,
                      picture: images.picture, conversation: dmConversation,
                      groupName: groupName, members: members)
    }
    guard images.avatar != nil else { return nil }
    let conversation = message.kind == .channel
        ? "\(message.server):channel:\(message.channelID.map(String.init) ?? "None"):\(message.topic ?? "None")"
        : dmConversation
    return Sender(handle: senderHandle, name: title, avatar: images.avatar,
                  picture: images.picture, conversation: conversation)
}

import Foundation

// What a notification says: output.py's text, for banners and dry runs.

private let zeroWidthSpace = "\u{200B}"
// terminal-notifier reads values through NSUserDefaults: a leading "-" is
// another option and a leading ( { < [ " or ' is parsed as a property list.
// Dry runs print what it would have been sent.
private let riskyFirstCharacters: [Character] = ["-", "(", "{", "<", "[", "\"", "'"]

func safeArgument(_ text: String) -> String {
    guard let first = text.first, riskyFirstCharacters.contains(first) else { return text }
    return zeroWidthSpace + text
}

public func bannerTitle(_ message: Message) -> String {
    let title: String
    if message.kind == .channel {
        title = "\(message.senderName) (#\(message.channelName ?? "None") > \(message.topic ?? "None"))"
    } else if message.dmUserIDs.count > 1 {
        title = "\(message.senderName) (group)"
    } else {
        title = message.senderName
    }
    return expandEmoji(title)
}

/// The message as plain text, cut to limit code points (as Python counts).
public func plainBody(_ message: Message, limit: Int = 200) -> String {
    let text = plainText(message.content)
    if text.isEmpty {
        return "(no text)"
    }
    guard text.unicodeScalars.count > limit else { return text }
    return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit - 1))) + "…"
}

public func bannerBody(_ message: Message, limit: Int = 200) -> String {
    let text = plainBody(message, limit: limit)
    return message.content.pythonStripped().isEmpty ? text : safeArgument(text)
}

/// The id a message's banner or alert carries, so it can be cleared.
public func groupID(server: String, id: Int) -> String {
    "z-iris-\(server)-\(id)"
}

public func bannerGroup(_ message: Message) -> String {
    groupID(server: message.server, id: message.id)
}

/// A batch summary's heading, else the sender and place.
public func notificationTitle(_ notification: Notification) -> String {
    if let summary = notification.summary, !summary.isEmpty {
        return expandEmoji(summary)
    }
    return bannerTitle(notification.message)
}

/// The banner's body: just "New message" for title-only banners.
public func notificationBody(_ notification: Notification) -> String {
    notification.action.banner == "title" ? "New message" : plainBody(notification.message)
}

/// sox's argv for a sound, as the dry run describes it.
public func soundCommand(player: [String], sound: String, volume: Int) -> [String] {
    // The vol effect, not the -v input option, which sox ignores for some input.
    player + [sound, "vol", String(format: "%.2f", Double(volume) / 100)]
}

/// What a dry run prints for a delivered notification.
public func dryRunText(_ notification: Notification, player: [String]) -> String {
    let action = notification.action
    let sound = audible(notification)
        ? soundCommand(player: player, sound: action.sound, volume: action.volume).joined(separator: " ")
        : "silent"
    let keep = action.sticky ? "sticky " : action.stay > 0 ? "stays \(action.stay)s " : ""
    let banner = action.banner == "off" ? "no banner" : "\(keep)banner \(action.banner)"
    let flash = action.flash == "none" ? "" : ", flash \(action.flash)"
    return """
    [dry-run] \(notification.message.server) (\(notification.reason)): \(notificationTitle(notification))
              \(bannerBody(notification.message, limit: 80))
              open \(notification.url)
              rule \(action.rule.flatMap { $0.isEmpty ? nil : $0 } ?? "default"), \(banner), sound \(sound)\(flash)
    """
}

public func dryRunClearText(server: String, ids: Set<Int>?) -> String {
    let what = ids.map { "\($0.count) read messages" } ?? "all read messages"
    return "[dry-run] \(server): clear sticky alerts for \(what)"
}

public func dryRunClearUnlessText(server: String, unread: Set<Int>) -> String {
    "[dry-run] \(server): clear sticky alerts except \(unread.count) unread"
}

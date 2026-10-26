import Foundation

// Run recent Zulip messages through a draft config, to show what rules do.
// Fetching the messages is ZulipKit's job; this is the evaluation.

public let snippetLength = 200

public struct PreviewEntry: Sendable, Equatable {
    public var id: Int
    public var sender: String
    public var place: String
    public var text: String
    public var why: String
    public var ruleIndex: Int?
    public var notify: Bool
    /// The sound's name ("none" for silence), when it would notify.
    public var sound: String?
    public var volume: Int?
}

private func place(_ message: Message) -> String {
    if message.kind == .channel {
        return "#\(message.channelName ?? "None") > \(message.topic ?? "None")"
    }
    return message.dmUserIDs.count > 1 ? "Group DM" : "DM"
}

/// The message text on one line, cut to snippetLength characters (code
/// points, as Python counts).
func snippet(_ content: String) -> String {
    let text = content.pythonWords.joined(separator: " ")
    let scalars = text.unicodeScalars
    guard scalars.count > snippetLength else { return text }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars.prefix(snippetLength - 1))
    return String(view) + "…"
}

/// Each raw message (as the messages API returns it), newest first, with
/// what the draft config would do to it. Malformed messages are skipped.
public func previewEntries(_ messages: [[String: Any]], pipeline: Pipeline) -> [PreviewEntry] {
    var entries: [PreviewEntry] = []
    for raw in messages.reversed() {
        let event: [String: Any] = ["message": raw, "flags": raw["flags"] ?? [Any]()]
        guard let message = try? Message(
            server: pipeline.server, host: pipeline.host, selfID: pipeline.selfID, event: event
        ) else { continue }
        let verdict = pipeline.evaluate(message)
        var entry = PreviewEntry(
            id: message.id, sender: message.senderName, place: place(message),
            text: snippet(message.content), why: verdict.why, ruleIndex: verdict.ruleIndex,
            notify: verdict.notification != nil
        )
        if let action = verdict.notification?.action {
            entry.sound = action.sound == "none"
                ? "none" : ((action.sound as NSString).lastPathComponent as NSString).deletingPathExtension
            entry.volume = action.volume
        }
        entries.append(entry)
    }
    return entries
}

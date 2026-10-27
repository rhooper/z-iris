import Foundation

// A batch summary's text, written by a language model (new in the Swift
// version; the Foundation Models one is in ZIrisMac).

public protocol Summarizer: Sendable {
    /// One short sentence about these messages, or nil when it cannot.
    func summarize(_ messages: [Message]) async -> String?
}

/// The messages as the model reads them: where, then "sender: text" lines,
/// newest last, within a character budget (the on-device context is small).
public func summaryPrompt(_ messages: [Message], budget: Int = 3000) -> String {
    var lines: [String] = []
    var used = 0
    var place: String?
    for message in messages.reversed() {
        let here = message.kind == .channel
            ? "#\(message.channelName ?? "") > \(message.topic ?? "")"
            : (message.dmUserIDs.count > 1 ? "a group chat" : "a direct message")
        let text = plainText(message.content)
        let line = "\(message.senderName): \(text.unicodeScalars.count > 400 ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(399))) + "…" : text)"
        if used + line.count > budget, !lines.isEmpty { break }
        used += line.count
        lines.append(line)
        if place == nil { place = here } else if place != here { place = "several conversations" }
    }
    return "Messages in \(place ?? "a conversation"):\n" + lines.reversed().joined(separator: "\n")
}

/// The model's reply as a notification body: one line, no quotes, capped.
public func summaryText(_ reply: String) -> String? {
    var text = reply.pythonWords.joined(separator: " ")
    for quote in ["\"", "“", "”", "'"] where text.hasPrefix(quote) || text.hasSuffix(quote) {
        text = text.trimmingCharacters(in: .init(charactersIn: quote))
    }
    guard !text.isEmpty else { return nil }
    return text.unicodeScalars.count > 200 ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(199))) + "…" : text
}


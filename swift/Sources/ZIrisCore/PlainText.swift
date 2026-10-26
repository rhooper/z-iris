import Foundation

// Turn Zulip markdown into the plain text a macOS notification can show.
// Notifications cannot show bold, links or any other formatting, so the
// markers are removed and the useful part kept. Emoji shortcodes become real
// emoji. The patterns are plaintext.py's, in ICU syntax.

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern)
}

private let fence = regex("(?s)```[ \\t]*([^\\n`]*)\\n?(.*?)(?:```|\\z)")
private let image = regex("!\\[([^\\]]*)\\]\\([^)]*\\)")
private let link = regex("\\[([^\\]]+)\\]\\(([^)]*)\\)")
private let user = regex("@(_?)\\*\\*([^*|]+?)(?:\\|\\d+)?\\*\\*")
private let group = regex("@\\*([^*\\n]+)\\*")
private let channel = regex("#\\*\\*([^*>]+?)(?:>([^*]+?))?\\*\\*")
private let bold = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
private let strike = regex("~~(?=\\S)(.+?)(?<=\\S)~~")
private let italicStar = regex("(?<![\\w*])\\*(?=[^\\s*])([^*\\n]+?)(?<=[^\\s*])\\*(?![\\w*])")
private let italicUnder = regex("(?<![\\w_])_(?=[^\\s_])([^_\\n]+?)(?<=[^\\s_])_(?![\\w_])")
private let code = regex("`([^`\\n]+)`")
private let time = regex("<time:[^>]*>")
// Not inside a word, so a:b:c is not read as :b:.
private let shortcode = regex("(?<!\\w):([\\w+\\-]+):(?!\\w)")
private let horizontalRule = regex("^\\s*([-*_])(?:\\s*\\1){2,}\\s*$")
private let listItem = regex("^(\\s*)[-*+]\\s+")
private let heading = regex("^\\s{0,3}#{1,6}\\s+")
private let quote = regex("^\\s*>+\\s?")

/// Shortcode name to emoji: Zulip's names over the emoji package's aliases
/// (scripts/claude/dump_emoji.py).
private let emojiNames: [String: String] = {
    guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let table = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return table
}()

/// re.sub with a function: each non-overlapping match, left to right.
private func sub(_ regex: NSRegularExpression, _ text: String, count: Int = 0,
                 _ replace: ([String?]) -> String) -> String {
    let ns = text as NSString
    var out = ""
    var last = 0
    var done = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if count > 0, done == count { break }
        let groups = (0..<match.numberOfRanges).map { index -> String? in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
        out += replace(groups)
        last = match.range.location + match.range.length
        done += 1
    }
    return out + ns.substring(from: last)
}

private func matchesStart(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, options: .anchored, range: NSRange(text.startIndex..., in: text)) != nil
}

/// Python's str.isspace() characters, for split() and strip().
private let pythonSpace: Set<Unicode.Scalar> = [
    "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}", " ",
    "\u{85}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
    "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}",
    "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
]

extension String {
    /// Python's str.split() with no arguments.
    var pythonWords: [String] {
        unicodeScalars.split { pythonSpace.contains($0) }.map { String(String.UnicodeScalarView($0)) }
    }

    /// Python's str.strip(), or strip(characters).
    func pythonStripped(_ characters: Set<Unicode.Scalar>? = nil) -> String {
        let set = characters ?? pythonSpace
        let scalars = Array(unicodeScalars)
        guard let first = scalars.firstIndex(where: { !set.contains($0) }) else { return "" }
        let last = scalars.lastIndex { !set.contains($0) }!
        return String(String.UnicodeScalarView(scalars[first...last]))
    }
}

private func fenceText(_ groups: [String?]) -> String {
    let header = (groups[1] ?? "").pythonStripped()
    let body = (groups[2] ?? "").pythonStripped(["\n"])
    let kind = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map { String($0).pythonLowercased } ?? ""
    if kind == "spoiler" {
        let title = String(header.dropFirst("spoiler".count)).pythonStripped()
        return title.isEmpty ? "[spoiler]" : "[spoiler: \(title)]"
    }
    return "\n\(body)\n"
}

/// Replace :shortcodes: with their emoji; unknown ones (custom realm emoji)
/// stay as written.
public func expandEmoji(_ text: String) -> String {
    sub(shortcode, text) { groups in emojiNames[groups[1]!] ?? groups[0]! }
}

/// Plain text for a notification body.
public func plainText(_ markdown: String) -> String {
    var text = sub(fence, markdown.replacingOccurrences(of: "\r\n", with: "\n"), fenceText)
    text = sub(image, text) { groups in
        let alt = groups[1]!.pythonStripped()
        return "🖼 \(alt.isEmpty ? "image" : alt)"
    }
    text = sub(link, text) { groups in
        groups[2]!.hasPrefix("/user_uploads/") ? "📎 \(groups[1]!)" : groups[1]!
    }
    text = sub(user, text) { groups in (groups[1]!.isEmpty ? "@" : "") + groups[2]! }
    text = sub(group, text) { groups in "@\(groups[1]!)" }
    text = sub(channel, text) { groups in
        groups[2].map { "#\(groups[1]!) > \($0)" } ?? "#\(groups[1]!)"
    }
    text = sub(time, text) { _ in "" }

    var lines: [String] = []
    for var line in text.components(separatedBy: "\n") {
        if matchesStart(horizontalRule, line) {
            continue
        }
        line = sub(heading, line, count: 1) { _ in "" }
        line = sub(quote, line, count: 1) { _ in "" }
        line = sub(listItem, line, count: 1) { groups in "\(groups[1]!)• " }
        lines.append(line)
    }
    text = lines.joined(separator: "\n")

    text = sub(bold, text) { $0[2]! }
    text = sub(strike, text) { $0[1]! }
    text = sub(italicStar, text) { $0[1]! }
    text = sub(italicUnder, text) { $0[1]! }
    text = sub(code, text) { $0[1]! }
    text = expandEmoji(text)
    return text.pythonWords.joined(separator: " ")
}

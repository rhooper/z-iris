import Foundation

// A TOML file as tomlkit sees it, so edits keep every comment and line and
// produce the same bytes tomlkit does: sections (the top level, then one per
// header), each a list of key/value, comment and whitespace items. Comments
// and blank lines before a header belong to the section above it.

public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])

    /// The value as tomlkit writes a new one.
    var rendered: String {
        switch self {
        case .string(let text): return basicString(text)
        case .integer(let number): return String(number)
        case .float(let number): return pythonRepr(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items): return "[" + items.map(\.rendered).joined(separator: ", ") + "]"
        }
    }
}

/// tomlkit's escaping for a basic string.
private func basicString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\t": out += "\\t"
        case "\n": out += "\\n"
        case "\u{0C}": out += "\\f"
        case "\r": out += "\\r"
        case _ where scalar.value < 0x20 || scalar.value == 0x7F:
            out += "\\u" + String(format: "%04x", scalar.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

public struct EditingError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

struct TOMLSpans {
    enum Item {
        /// prefix is indent, key and " = "; suffix is spacing, comment and newline.
        case keyValue(key: [String], prefix: String, value: String, suffix: String)
        case comment(String)
        case whitespace(String)

        var text: String {
            switch self {
            case let .keyValue(_, prefix, value, suffix): prefix + value + suffix
            case let .comment(text), let .whitespace(text): text
            }
        }

        // Not hasSuffix("\n"): "\r\n" is one Character.
        var endsLine: Bool { text.unicodeScalars.last == "\n" }
    }

    struct Section {
        /// Text tomlkit puts before a table it appended: "\n" or "".
        var lead = ""
        /// The header line; nil for the top level.
        var header: String?
        var path: [String] = []
        var isArray = false
        var items: [Item] = []

        var text: String { lead + (header ?? "") + items.map(\.text).joined() }
    }

    var sections: [Section]

    var text: String { sections.map(\.text).joined() }

    init(_ source: String) throws(EditingError) {
        var scanner = SpanScanner(Array(source.unicodeScalars))
        sections = try scanner.document()
    }

    // MARK: queries

    func indices(path: [String], isArray: Bool) -> [Int] {
        sections.indices.filter { sections[$0].header != nil && sections[$0].path == path && sections[$0].isArray == isArray }
    }

    // MARK: edits

    /// Set a key in a section: in place when it exists (keeping its spacing
    /// and comment), else a new line after the last item that is not blank.
    mutating func set(_ key: String, _ value: TOMLValue, in index: Int) {
        var items = sections[index].items
        if let at = items.firstIndex(where: { if case let .keyValue(k, _, _, _) = $0 { k == [key] } else { false } }),
           case let .keyValue(k, prefix, _, suffix) = items[at] {
            items[at] = .keyValue(key: k, prefix: prefix, value: value.rendered, suffix: suffix)
        } else {
            let line = Item.keyValue(key: [key], prefix: "\(key) = ", value: value.rendered, suffix: "\n")
            if let last = items.lastIndex(where: { if case .whitespace = $0 { false } else { true } }) {
                items[last] = Self.endingLine(items[last])
                items.insert(line, at: last + 1)
            } else {
                if let header = sections[index].header, header.unicodeScalars.last != "\n" {
                    sections[index].header = header + "\n"
                }
                items.insert(line, at: 0)
            }
        }
        sections[index].items = items
    }

    mutating func remove(_ key: String, in index: Int) {
        sections[index].items.removeAll { if case let .keyValue(k, _, _, _) = $0 { k == [key] } else { false } }
    }

    /// Append a table at the end, as tomlkit does: after a blank line unless
    /// the file already ends on whitespace. An array table first ends an
    /// unfinished last line; a plain table's "\n" does that instead.
    mutating func append(path: [String], isArray: Bool, keys: [(String, TOMLValue)]) {
        var lead = ""
        if let at = sections.lastIndex(where: { $0.header != nil || !$0.items.isEmpty }) {
            if let item = sections[at].items.last {
                if case .whitespace = item {} else {
                    lead = "\n"
                    if isArray {
                        sections[at].items[sections[at].items.count - 1] = Self.endingLine(item)
                    }
                }
            } else {
                lead = "\n"
                if isArray, let header = sections[at].header, header.unicodeScalars.last != "\n" {
                    sections[at].header = header + "\n"
                }
            }
        }
        let name = path.joined(separator: ".")
        var section = Section(lead: lead, header: isArray ? "[[\(name)]]\n" : "[\(name)]\n", path: path, isArray: isArray)
        section.items = keys.map { .keyValue(key: [$0.0], prefix: "\($0.0) = ", value: $0.1.rendered, suffix: "\n") }
        sections.append(section)
    }

    /// Remove every section under a top-level name ([[rule]] and [rule.x]).
    mutating func removeSections(named name: String) {
        sections.removeAll { $0.header != nil && $0.path.first == name }
    }

    private static func endingLine(_ item: Item) -> Item {
        guard !item.endsLine else { return item }
        switch item {
        case let .keyValue(key, prefix, value, suffix): return .keyValue(key: key, prefix: prefix, value: value, suffix: suffix + "\n")
        case let .comment(text): return .comment(text + "\n")
        case let .whitespace(text): return .whitespace(text + "\n")
        }
    }
}

/// Splits TOML text into sections and items. It finds where things are; the
/// values themselves are read with TOMLDecoder.
private struct SpanScanner {
    let chars: [Unicode.Scalar]
    var index = 0

    init(_ chars: [Unicode.Scalar]) {
        self.chars = chars
    }

    func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    func text(_ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: chars[from..<to])
        return String(view)
    }

    func fail(_ what: String) -> EditingError {
        EditingError(description: "cannot edit this config: \(what) at character \(index)")
    }

    mutating func skipBlanks() {
        while let char = peek(), char == " " || char == "\t" { index += 1 }
    }

    /// Past the end of the line: its newline, if any.
    mutating func lineEnd() throws(EditingError) {
        if peek() == "\r", peek(1) == "\n" {
            index += 2
        } else if peek() == "\n" {
            index += 1
        } else if peek() != nil {
            throw fail("unexpected text")
        }
    }

    mutating func restOfLine() throws(EditingError) {
        skipBlanks()
        if peek() == "#" {
            while let char = peek(), char != "\n" { index += 1 }
            if index > 0, chars[index - 1] == "\r" { index -= 1 }
        }
        try lineEnd()
    }

    mutating func document() throws(EditingError) -> [TOMLSpans.Section] {
        var sections = [TOMLSpans.Section()]
        while index < chars.count {
            let start = index
            skipBlanks()
            switch peek() {
            case nil, "\n", "\r":
                try lineEnd()
                let blank = text(start, index)
                if case let .whitespace(previous)? = sections[sections.count - 1].items.last {
                    sections[sections.count - 1].items[sections[sections.count - 1].items.count - 1] = .whitespace(previous + blank)
                } else {
                    sections[sections.count - 1].items.append(.whitespace(blank))
                }
            case "#":
                try restOfLine()
                sections[sections.count - 1].items.append(.comment(text(start, index)))
            case "[":
                let isArray = peek(1) == "["
                index += isArray ? 2 : 1
                let path = try keyPath()
                guard peek() == "]", !isArray || peek(1) == "]" else { throw fail("bad table header") }
                index += isArray ? 2 : 1
                try restOfLine()
                sections.append(TOMLSpans.Section(header: text(start, index), path: path, isArray: isArray))
            default:
                let key = try keyPath()
                guard peek() == "=" else { throw fail("expected =") }
                index += 1
                skipBlanks()
                let prefix = text(start, index)
                let valueStart = index
                try value()
                let valueEnd = index
                try restOfLine()
                sections[sections.count - 1].items.append(.keyValue(
                    key: key, prefix: prefix, value: text(valueStart, valueEnd), suffix: text(valueEnd, index)
                ))
            }
        }
        return sections
    }

    /// A dotted key, bare or quoted parts, with blanks around the dots.
    mutating func keyPath() throws(EditingError) -> [String] {
        var parts: [String] = []
        while true {
            skipBlanks()
            parts.append(try keyPart())
            skipBlanks()
            guard peek() == "." else { return parts }
            index += 1
        }
    }

    mutating func keyPart() throws(EditingError) -> String {
        switch peek() {
        case "\"":
            let start = index
            try basic()
            return try unescape(text(start + 1, index - 1))
        case "'":
            let start = index
            try literal()
            return text(start + 1, index - 1)
        default:
            let start = index
            while let char = peek(), ("a"..."z").contains(char) || ("A"..."Z").contains(char)
                || ("0"..."9").contains(char) || char == "_" || char == "-" {
                index += 1
            }
            guard index > start else { throw fail("bad key") }
            return text(start, index)
        }
    }

    mutating func value() throws(EditingError) {
        switch peek() {
        case "\"":
            if peek(1) == "\"", peek(2) == "\"" { try multiline("\"", escapes: true) } else { try basic() }
        case "'":
            if peek(1) == "'", peek(2) == "'" { try multiline("'", escapes: false) } else { try literal() }
        case "[":
            try bracketed(open: "[", close: "]")
        case "{":
            try bracketed(open: "{", close: "}")
        default:
            let start = index
            while let char = peek(), char != "#", char != "\n", char != "\r" { index += 1 }
            while index > start, chars[index - 1] == " " || chars[index - 1] == "\t" { index -= 1 }
            guard index > start else { throw fail("missing value") }
        }
    }

    mutating func basic() throws(EditingError) {
        index += 1
        while let char = peek() {
            index += 1
            if char == "\\" { index += 1 } else if char == "\"" { return }
            if char == "\n" { break }
        }
        throw fail("unterminated string")
    }

    mutating func literal() throws(EditingError) {
        index += 1
        while let char = peek() {
            index += 1
            if char == "'" { return }
            if char == "\n" { break }
        }
        throw fail("unterminated string")
    }

    mutating func multiline(_ quote: Unicode.Scalar, escapes: Bool) throws(EditingError) {
        index += 3
        while let char = peek() {
            if escapes, char == "\\" {
                index += 2
                continue
            }
            if char == quote, peek(1) == quote, peek(2) == quote {
                index += 3
                // Up to two more quotes belong to the content.
                var extra = 0
                while extra < 2, peek() == quote {
                    index += 1
                    extra += 1
                }
                return
            }
            index += 1
        }
        throw fail("unterminated string")
    }

    /// An array or inline table, skipping strings and comments inside.
    mutating func bracketed(open: Unicode.Scalar, close: Unicode.Scalar) throws(EditingError) {
        index += 1
        while let char = peek() {
            switch char {
            case close:
                index += 1
                return
            case "\"", "'", "[", "{":
                try value()
            case "#":
                while let next = peek(), next != "\n" { index += 1 }
            default:
                index += 1
            }
        }
        throw fail("unterminated \(open)")
    }

    func unescape(_ raw: String) throws(EditingError) -> String {
        var out = String.UnicodeScalarView()
        var scalars = raw.unicodeScalars.makeIterator()
        while let char = scalars.next() {
            guard char == "\\" else {
                out.append(char)
                continue
            }
            switch scalars.next() {
            case "b": out.append("\u{08}")
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "f": out.append("\u{0C}")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case let kind? where kind == "u" || kind == "U":
                var hex = ""
                for _ in 0..<(kind == "u" ? 4 : 8) {
                    guard let digit = scalars.next() else { throw fail("bad escape") }
                    hex.unicodeScalars.append(digit)
                }
                guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { throw fail("bad escape") }
                out.append(scalar)
            default:
                throw fail("bad escape")
            }
        }
        return String(out)
    }
}

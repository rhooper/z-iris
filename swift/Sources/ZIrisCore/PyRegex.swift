import Foundation

/// A Python `re` pattern, compiled case-insensitively with NSRegularExpression.
/// Python-only syntax is translated; syntax Python rejects, or that ICU would
/// read differently, is refused so a config means the same in both versions.
public struct PyRegex: Sendable, Equatable {
    public let source: String
    private let regex: NSRegularExpression
    private let whole: NSRegularExpression

    public struct Error: Swift.Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public init(_ source: String) throws(Error) {
        self.source = source
        let translated = try Self.translate(source)
        do {
            regex = try NSRegularExpression(pattern: translated, options: [.caseInsensitive])
            whole = try NSRegularExpression(pattern: "\\A(?:\(translated))\\z", options: [.caseInsensitive])
        } catch {
            throw Error(description: "invalid pattern")
        }
    }

    public static func == (lhs: PyRegex, rhs: PyRegex) -> Bool { lhs.source == rhs.source }

    /// re.search: the first match anywhere, as a UTF-16 range.
    public func search(_ text: String) -> NSRange? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    /// re.fullmatch.
    public func fullMatch(_ text: String) -> Bool {
        whole.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func translate(_ source: String) throws(Error) -> String {
        var scanner = Translator(chars: Array(source))
        let out = try scanner.run()
        return out.isEmpty ? "(?:)" : out
    }
}

/// Rewrites Python `re` syntax as ICU syntax, one token at a time.
private struct Translator {
    let chars: [Character]
    var index = 0
    var out = ""
    var openGroups: [Int] = []  // capture numbers still open
    var groupCount = 0

    // Escapes Python accepts after a backslash (besides digits and non-letters).
    static let letterEscapes: Set<Character> = [
        "a", "b", "B", "d", "D", "f", "n", "r", "s", "S", "t", "v", "w", "W", "Z", "A",
        "x", "u", "U", "N",
    ]

    func peek(_ offset: Int = 0) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    func fail(_ text: String) -> PyRegex.Error { PyRegex.Error(description: text) }

    mutating func run() throws(PyRegex.Error) -> String {
        while let char = peek() {
            switch char {
            case "\\": try escape(inClass: false)
            case "[": try characterClass()
            case "(": try group()
            case ")":
                if !openGroups.isEmpty { openGroups.removeLast() }
                out += ")"
                index += 1
            case "{": quantifier()
            case "}":
                out += "\\}"
                index += 1
            default:
                out.append(char)
                index += 1
            }
        }
        return out
    }

    /// One backslash escape. Returns the literal character it stands for when
    /// it is a single character (for range checks in classes), else nil.
    @discardableResult
    mutating func escape(inClass: Bool) throws(PyRegex.Error) -> Character? {
        guard let next = peek(1) else { throw fail("bad escape (end of pattern)") }
        index += 2
        if next.isASCII, next.isNumber {
            return try numericEscape(first: next, inClass: inClass)
        }
        guard next.isASCII, next.isLetter else {
            out += "\\\(next)"
            return next
        }
        guard Self.letterEscapes.contains(next) else { throw fail("bad escape \\\(next)") }
        switch next {
        case "Z": out += inClass ? "Z" : "\\z"
        case "v": out += "\\x{0B}"
        case "b" where inClass: out += "\\x{08}"
        case "N":
            guard peek() == "{", let close = chars[index...].firstIndex(of: "}") else {
                throw fail("missing {")
            }
            out += "\\N" + String(chars[index...close])
            index = close + 1
        case "x", "u", "U":
            let width = ["x": 2, "u": 4, "U": 8][next]!
            let digits = chars[index..<min(index + width, chars.count)]
            guard digits.count == width, digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(String(digits), radix: 16), let scalar = Unicode.Scalar(value)
            else { throw fail("incomplete escape \\\(next)") }
            index += width
            out += "\\x{\(String(value, radix: 16))}"
            return Character(scalar)
        default: out += "\\\(next)"
        }
        return nil
    }

    /// \0, octal \ooo, or a back reference \n (Python refuses one to a
    /// group not yet closed; ICU allows forward references).
    mutating func numericEscape(first: Character, inClass: Bool) throws(PyRegex.Error) -> Character? {
        var digits = String(first)
        let octal: (Character?) -> Bool = { $0.map { "01234567".contains($0) } ?? false }
        if first == "0" {
            while digits.count < 3, octal(peek()) { digits.append(peek()!); index += 1 }
        } else if octal(first), octal(peek()), octal(peek(1)), first <= "3" {
            digits += String([peek()!, peek(1)!])
            index += 2
        } else {
            if inClass { throw fail("bad escape \\\(first)") }
            if let second = peek(), second.isASCII, second.isNumber {
                digits.append(second)
                index += 1
            }
            let group = Int(digits)!
            guard group <= groupCount, !openGroups.contains(group) else {
                throw fail("invalid group reference \(group)")
            }
            out += "\\\(group)"
            return nil
        }
        let value = UInt32(digits, radix: 8)!
        out += "\\x{\(String(value, radix: 16))}"
        return Unicode.Scalar(value).map(Character.init)
    }

    mutating func characterClass() throws(PyRegex.Error) {
        out += "["
        index += 1
        if peek() == "^" {
            out += "^"
            index += 1
        }
        let start = index
        var last: Character?  // a single character that could start a range
        while true {
            guard let char = peek() else { throw fail("unterminated character set") }
            if char == "]", index > start {
                out += "]"
                index += 1
                return
            }
            if char == "-", let low = last, let next = peek(1), next != "]" {
                index += 1
                out += "-"
                let high: Character?
                if next == "\\" {
                    high = try escape(inClass: true)
                } else {
                    high = next
                    out += "[&-]".contains(next) ? "\\\(next)" : String(next)
                    index += 1
                }
                guard let high else { throw fail("bad character range") }
                if low.unicodeScalars.first!.value > high.unicodeScalars.first!.value {
                    throw fail("bad character range \(low)-\(high)")
                }
                last = nil
                continue
            }
            if char == "\\" {
                last = try escape(inClass: true)
                // A class escape such as \d cannot start a range.
                if last == nil, peek() == "-", let next = peek(1), next != "]" {
                    throw fail("bad character range")
                }
                continue
            }
            // Python: a ] first in a class is literal; ICU nests sets with [ and
            // has && and -- operators, so those are escaped.
            out += "[]&-".contains(char) ? "\\\(char)" : String(char)
            last = char
            index += 1
        }
    }

    mutating func group() throws(PyRegex.Error) {
        guard peek(1) == "?" else {
            groupCount += 1
            openGroups.append(groupCount)
            out += "("
            index += 1
            return
        }
        let rest = String(chars[(index + 2)...].prefix(3))
        if rest.hasPrefix("P<") {
            groupCount += 1
            openGroups.append(groupCount)
            let close = chars[(index + 4)...].firstIndex(of: ">") ?? chars.count
            let name = String(chars[(index + 4)..<close])
            guard let head = name.first, head.isLetter || head == "_",
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { throw fail("bad character in group name") }
            out += "(?<"
            index += 4
            return
        }
        if rest.hasPrefix("P=") {
            guard let close = chars[(index + 4)...].firstIndex(of: ")") else {
                throw fail("missing ), unterminated name")
            }
            out += "\\k<\(String(chars[(index + 4)..<close]))>"
            index = close + 1
            return
        }
        if rest.hasPrefix("P") { throw fail("unknown extension ?P") }
        if rest.hasPrefix("<"), !rest.hasPrefix("<="), !rest.hasPrefix("<!") {
            throw fail("unknown extension ?<")  // Python names groups only with ?P<
        }
        // A global flag group like (?i) is only allowed at the very start.
        if let close = chars[(index + 2)...].firstIndex(of: ")"),
           close > index + 2, chars[(index + 2)..<close].allSatisfy({ "aiLmsux".contains($0) }) {
            if index != 0 { throw fail("global flags not at the start of the expression") }
        }
        openGroups.append(0)  // non-capturing, lookaround or flags; closes like a group
        out += "(?"
        index += 2
    }

    /// Python reads {m}, {m,}, {,n} and {m,n} as repeats and any other brace
    /// as a literal; ICU refuses a stray brace and has no {,n}.
    mutating func quantifier() {
        var cursor = index + 1
        var low = "", high = ""
        var comma = false
        while cursor < chars.count, chars[cursor] != "}" {
            let char = chars[cursor]
            if char == ",", !comma {
                comma = true
            } else if char.isASCII, char.isNumber {
                if comma { high.append(char) } else { low.append(char) }
            } else {
                break
            }
            cursor += 1
        }
        guard cursor < chars.count, chars[cursor] == "}", !(low.isEmpty && high.isEmpty) else {
            out += "\\{"
            index += 1
            return
        }
        out += comma ? "{\(low.isEmpty ? "0" : low),\(high)}" : "{\(low)}"
        index = cursor + 1
    }
}

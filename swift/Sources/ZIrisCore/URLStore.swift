import Foundation

// Each notification's click URL by group id, on disk, so a click that
// relaunches the app after it quit still opens the right conversation
// (priority.UrlStore). The file is a flat JSON object in insertion order,
// written as Python's json.dump writes it, so both versions share it.

public final class URLStore: @unchecked Sendable {
    public let url: URL
    /// Most notifications are never clicked; keep the newest.
    public let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = 500) {
        self.url = url
        self.limit = limit
    }

    public func put(_ group: String, _ link: String) {
        lock.withLock {
            var entries = read().filter { $0.0 != group }
            entries.append((group, link))
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
            write(entries)
        }
    }

    public func pop(_ group: String) -> String? {
        lock.withLock {
            var entries = read()
            guard let index = entries.firstIndex(where: { $0.0 == group }) else { return nil }
            let link = entries.remove(at: index).1
            write(entries)
            return link
        }
    }

    public func drop(_ groups: some Sequence<String>) {
        lock.withLock {
            let doomed = Set(groups)
            let entries = read()
            let kept = entries.filter { !doomed.contains($0.0) }
            if kept.count != entries.count {
                write(kept)
            }
        }
    }

    private func read() -> [(String, String)] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(String(decoding: data, as: UTF8.self)) ?? []
    }

    private func write(_ entries: [(String, String)]) {
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard (try? Data(Self.encode(entries).utf8).write(to: temporary)) != nil else { return }
        if (try? files.replaceItemAt(url, withItemAt: temporary)) == nil {
            try? files.removeItem(at: temporary)
        }
    }

    /// json.dump's form: {"k": "v", ...}, non-ASCII as \uXXXX.
    static func encode(_ entries: [(String, String)]) -> String {
        "{" + entries.map { "\(quote($0.0)): \(quote($0.1))" }.joined(separator: ", ") + "}"
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }

    /// A flat object of strings, keys in file order; nil for anything else
    /// (Python's reader also starts over from an empty store).
    static func decode(_ text: String) -> [(String, String)]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        // Keys in order: every string token at depth 1 that is followed by ":".
        var keys: [String] = []
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            guard units[index] == 0x22 else { index += 1; continue }
            var end = index + 1
            while end < units.count, units[end] != 0x22 {
                end += units[end] == 0x5C ? 2 : 1
            }
            var after = end + 1
            while after < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[after]) { after += 1 }
            let token = String(decoding: units[index...min(end, units.count - 1)], as: UTF16.self)
            if after < units.count, units[after] == 0x3A,
               let key = (try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed)) as? String {
                keys.append(key)
            }
            index = end + 1
        }
        var seen = Set<String>()
        return keys.compactMap { key in
            guard seen.insert(key).inserted, let value = object[key] as? String else { return nil }
            return (key, value)
        }
    }
}

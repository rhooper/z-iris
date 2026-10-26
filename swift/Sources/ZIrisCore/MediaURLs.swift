import Foundation

// Which URLs a notification may fetch, and with what: media.py's pure part.
// Its decisions rest on Python's urlparse and urljoin, which Foundation's URL
// does not match (params, port 0, unencoded text), so those are ported too.

/// urllib.parse.urlparse's parts.
struct PyURL {
    var scheme = ""
    var netloc = ""
    var path = ""
    var params = ""
    var query = ""
    var fragment = ""

    private static let schemeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")

    init(_ text: String, defaultScheme: String = "") {
        // urlsplit drops leading C0 controls and spaces, and every tab and newline.
        var url = String(text.unicodeScalars.drop { $0.value <= 0x20 }.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }
            .map(Character.init))
        scheme = defaultScheme
        if let colon = url.firstIndex(of: ":"), colon > url.startIndex,
           url.first!.isASCII, url.first!.isLetter, url[..<colon].allSatisfy(Self.schemeCharacters.contains) {
            scheme = url[..<colon].lowercased()
            url = String(url[url.index(after: colon)...])
        }
        if url.hasPrefix("//") {
            let rest = url.dropFirst(2)
            let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
            netloc = String(rest[..<end])
            url = String(rest[end...])
        }
        if let hash = url.firstIndex(of: "#") {
            fragment = String(url[url.index(after: hash)...])
            url = String(url[..<hash])
        }
        if let mark = url.firstIndex(of: "?") {
            query = String(url[url.index(after: mark)...])
            url = String(url[..<mark])
        }
        // urlparse splits ;params off the last path segment.
        let lastSlash = url.lastIndex(of: "/") ?? url.startIndex
        if let semicolon = url[lastSlash...].firstIndex(of: ";") {
            params = String(url[url.index(after: semicolon)...])
            url = String(url[..<semicolon])
        }
        path = url
    }

    private var hostPort: Substring {
        netloc.lastIndex(of: "@").map { netloc[netloc.index(after: $0)...] } ?? netloc[...]
    }

    /// The host, lowercased, or nil.
    var hostname: String? {
        let host: Substring
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            host = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
        } else {
            host = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    /// The port; nil when absent; throws (ValueError) when it is not one.
    func port() throws -> Int? {
        let text: Substring
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            let after = hostPort[hostPort.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            text = after.dropFirst()
        } else {
            guard let colon = hostPort.lastIndex(of: ":") else { return nil }
            text = hostPort[hostPort.index(after: colon)...]
        }
        if text.isEmpty { return nil }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(text), (0...65535).contains(port) else {
            throw PortError()
        }
        return port
    }

    struct PortError: Error {}

    /// urlunparse.
    var text: String {
        var url = params.isEmpty ? path : path + ";" + params
        if !netloc.isEmpty {
            if !url.isEmpty, !url.hasPrefix("/") { url = "/" + url }
            url = "//" + netloc + url
        } else if url.hasPrefix("//") {
            url = "//" + url
        }
        if !scheme.isEmpty { url = scheme + ":" + url }
        if !query.isEmpty { url += "?" + query }
        if !fragment.isEmpty { url += "#" + fragment }
        return url
    }
}

private let relativeSchemes: Set<String> = [
    "", "ftp", "http", "gopher", "nntp", "imap", "wais", "file", "https", "shttp", "mms",
    "prospero", "rtsp", "rtsps", "rtspu", "sftp", "svn", "svn+ssh", "ws", "wss",
]
private let netlocSchemes: Set<String> = [
    "", "ftp", "http", "gopher", "nntp", "telnet", "imap", "wais", "file", "mms", "https",
    "shttp", "snews", "prospero", "rtsp", "rtsps", "rtspu", "rsync", "svn", "svn+ssh", "sftp",
    "nfs", "git", "git+ssh", "ws", "wss", "itms-services",
]

/// urllib.parse.urljoin.
public func pyURLJoin(_ base: String, _ url: String) -> String {
    if base.isEmpty { return url }
    if url.isEmpty { return base }
    let b = PyURL(base)
    var u = PyURL(url, defaultScheme: b.scheme)
    if u.scheme != b.scheme || !relativeSchemes.contains(u.scheme) {
        return url
    }
    if netlocSchemes.contains(u.scheme) {
        if !u.netloc.isEmpty { return u.text }
        u.netloc = b.netloc
    }
    if u.path.isEmpty, u.params.isEmpty {
        u.path = b.path
        u.params = b.params
        if u.query.isEmpty { u.query = b.query }
        return u.text
    }
    var baseParts = b.path.components(separatedBy: "/")
    if baseParts.last != "" { baseParts.removeLast() }
    var segments: [String]
    if u.path.hasPrefix("/") {
        segments = u.path.components(separatedBy: "/")
    } else {
        segments = baseParts + u.path.components(separatedBy: "/")
        if segments.count > 2 {
            segments = [segments[0]] + segments[1..<(segments.count - 1)].filter { !$0.isEmpty } + [segments.last!]
        }
    }
    var resolved: [String] = []
    for segment in segments {
        if segment == ".." {
            if !resolved.isEmpty { resolved.removeLast() }
        } else if segment != "." {
            resolved.append(segment)
        }
    }
    if let last = segments.last, last == "." || last == ".." {
        resolved.append("")
    }
    let joined = resolved.joined(separator: "/")
    u.path = joined.isEmpty ? "/" : joined
    return u.text
}

private let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp"]
private let codeFence = try! NSRegularExpression(pattern: "(?s)```.*?(?:```|\\z)")
// Alternatives are tried left to right at each position: image syntax, then
// links to image files, then bare image URLs.
private let imagePattern = try! NSRegularExpression(
    pattern: "!\\[[^\\[\\]]*\\]\\(\\s*<?(?<img>[^()\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)"
        + "|\\[[^\\[\\]]*\\]\\(\\s*<?(?<link>[^()\\s>]+)>?(?:\\s+\"[^\"]*\")?\\s*\\)"
        + "|(?<bare>https?://[^\\s<>()\\[\\]]+)",
    options: [.caseInsensitive]
)

private func hasImageExtension(_ url: String) -> Bool {
    let path = PyURL(url).path.lowercased()
    return imageExtensions.contains { path.hasSuffix("." + $0) }
}

func webOrRelative(_ url: String) -> Bool {
    let scheme = PyURL(url).scheme.lowercased()
    return scheme == "http" || scheme == "https" || (scheme.isEmpty && url.hasPrefix("/"))
}

/// Image URLs in Zulip markdown, in order, without repeats. May be relative.
public func extractImageURLs(_ content: String) -> [String] {
    let ns = content as NSString
    let unfenced = codeFence.stringByReplacingMatches(
        in: content, range: NSRange(location: 0, length: ns.length), withTemplate: ""
    ) as NSString
    var found: [String] = []
    for match in imagePattern.matches(in: unfenced as String, range: NSRange(location: 0, length: unfenced.length)) {
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            return range.location == NSNotFound ? nil : unfenced.substring(with: range)
        }
        let url: String
        let needsExtension: Bool
        if let image = group("img") {
            (url, needsExtension) = (image, false)
        } else if let link = group("link") {
            (url, needsExtension) = (link, true)
        } else {
            url = String(group("bare")!.reversed().drop { ".,;:!?'\"".contains($0) }.reversed())
            needsExtension = true
        }
        if !webOrRelative(url) || (needsExtension && !hasImageExtension(url)) {
            continue
        }
        if !found.contains(url) {
            found.append(url)
        }
    }
    return found
}

private struct Origin: Equatable {
    var scheme: String
    var host: String
    var port: Int?
}

private func origin(_ url: String) -> Origin? {
    let parsed = PyURL(url)
    let scheme = parsed.scheme.lowercased()
    let port: Int?
    do {
        port = try parsed.port()
    } catch {
        return nil  // urlparse's ValueError
    }
    // `parsed.port or default`: port 0 counts as absent.
    let effective = (port == nil || port == 0) ? ["http": 80, "https": 443][scheme] : port
    guard scheme == "http" || scheme == "https", let host = parsed.hostname else { return nil }
    return Origin(scheme: scheme, host: host, port: effective)
}

public func sameOrigin(_ url: String, _ base: String) -> Bool {
    guard let mine = origin(url) else { return false }
    return mine == origin(base)
}

private let authPaths = ["/user_uploads/", "/user_avatars/", "/thumbnail"]

private func authPath(_ url: String) -> Bool {
    let path = PyURL(url).path
    return authPaths.contains { prefix in
        prefix.hasSuffix("/") ? path.hasPrefix(prefix) : (path == prefix || path.hasPrefix(prefix + "/"))
    }
}

/// True only for the Zulip server's own origin (scheme, host and port all
/// equal base's, so https stays https) and only for upload, avatar and
/// thumbnail paths.
public func credentialsAllowed(_ url: String, base: String) -> Bool {
    sameOrigin(url, base) && authPath(url)
}

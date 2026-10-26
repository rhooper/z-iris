import Foundation

/// A server's API credentials, read the way the Python zulip client reads a
/// zuliprc. The key never appears in a description, log or error.
public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let email: String
    let key: String
    /// The API base, ending "/api/", as zulip.Client's base_url.
    public let baseURL: URL

    public var description: String { "Credentials(\(email) at \(baseURL.absoluteString))" }
    public var debugDescription: String { description }

    /// The Authorization header value. Only ZulipClient and MediaFetcher send it.
    var authorization: String {
        "Basic " + Data("\(email):\(key)".utf8).base64EncodedString()
    }

    init(email: String, key: String, site: String) throws(ZuliprcError) {
        self.email = email
        self.key = key
        guard let url = URL(string: Self.baseURL(site: site)) else {
            throw ZuliprcError(description: "the site in the zuliprc is not a URL")
        }
        baseURL = url
    }

    /// zulip.Client's base_url: a scheme added, trailing "/" removed, "/api/" ensured.
    static func baseURL(site: String) -> String {
        var site = site
        if site.hasPrefix("localhost") {
            site = "http://" + site
        } else if !site.hasPrefix("http") {
            site = "https://" + site
        }
        while site.hasSuffix("/") { site.removeLast() }
        if !site.hasSuffix("/api") { site += "/api" }
        return site + "/"
    }

    /// The server's host, lowercased, as stream.host_of does.
    public var host: String {
        var host = baseURL.host(percentEncoded: false)?.lowercased() ?? ""
        if let port = baseURL.port { host += ":\(port)" }
        return host
    }
}

public struct ZuliprcError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public enum Zuliprc {
    /// Read a zuliprc. As zulip.Client does, ZULIP_API_KEY, ZULIP_EMAIL and
    /// ZULIP_SITE in the environment win over the file. Errors never quote it.
    public static func load(
        path: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ZuliprcError) -> Credentials {
        var key = environment["ZULIP_API_KEY"]
        var email = environment["ZULIP_EMAIL"]
        var site = environment["ZULIP_SITE"]
        let full = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        if let text = try? String(contentsOfFile: full, encoding: .utf8) {
            let api = section("api", in: text)
            key = key ?? api["key"]
            email = email ?? api["email"]
            site = site ?? api["site"]
        } else if key == nil || email == nil {
            throw ZuliprcError(description: "api_key or email not specified and file \(full) does not exist")
        }
        guard let key, let email else {
            throw ZuliprcError(description: "the zuliprc at \(full) has no [api] key or email")
        }
        guard let site else {
            throw ZuliprcError(description: "Missing Zulip server URL; specify via --site or ~/.zuliprc.")
        }
        return try Credentials(email: email, key: key, site: site)
    }

    /// One section of an INI file as configparser reads it: "key = value" or
    /// "key: value", keys case-insensitive, # and ; comment lines, indented
    /// lines continuing the previous value.
    static func section(_ name: String, in text: String) -> [String: String] {
        var values: [String: String] = [:]
        var current: String?
        var lastKey: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                lastKey = nil
                continue
            }
            guard current == name else { continue }
            if let first = rawLine.first, first == " " || first == "\t", let lastKey {
                values[lastKey, default: ""] += "\n" + line
                continue
            }
            guard let split = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            values[key] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        return values
    }
}

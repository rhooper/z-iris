import Foundation

/// A decoded JSON reply. JSONSerialization's trees are immutable, so passing
/// one between tasks is safe.
public struct JSONObject: @unchecked Sendable {
    public let value: [String: Any]

    public init(_ value: [String: Any]) {
        self.value = value
    }

    public subscript(key: String) -> Any? { value[key] }

    public var succeeded: Bool { value["result"] as? String == "success" }

    /// The server's message, or a fallback.
    public func message(or fallback: String) -> String {
        value["msg"] as? String ?? fallback
    }
}

/// The Zulip calls z-iris makes. EventStream and the preview take this, so
/// tests can stand in for a server.
public protocol ZulipAPI: Sendable {
    var credentials: Credentials { get }
    func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject
    func events(queueID: String, lastEventID: Int) async throws -> JSONObject
    func deregister(queueID: String) async throws -> JSONObject
    func profile() async throws -> JSONObject
    func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject
    func streams() async throws -> JSONObject
}

public struct ZulipClientError: Error, CustomStringConvertible {
    public var description: String
}

/// The REST API over URLSession, behaving as the Python zulip client does:
/// GET parameters in the query and others as a form, non-string values as
/// JSON, a 90 s long-poll that is simply retried when it times out, and up to
/// ten retries a second apart on a 5xx or a dropped connection once the
/// server has answered.
public final class ZulipClient: ZulipAPI, @unchecked Sendable {
    public let credentials: Credentials
    private let session: URLSession
    private let lock = NSLock()
    private var connected = false

    public init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public convenience init(zuliprc path: String) throws {
        self.init(credentials: try Zuliprc.load(path: path))
    }

    public func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject {
        try await call("register", method: "POST", [
            "event_types": eventTypes, "apply_markdown": applyMarkdown, "client_gravatar": clientGravatar,
        ])
    }

    public func events(queueID: String, lastEventID: Int) async throws -> JSONObject {
        try await call("events", method: "GET", ["queue_id": queueID, "last_event_id": lastEventID], longPolling: true)
    }

    public func deregister(queueID: String) async throws -> JSONObject {
        try await call("events", method: "DELETE", ["queue_id": queueID])
    }

    public func profile() async throws -> JSONObject {
        try await call("users/me", method: "GET", [:])
    }

    public func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject {
        try await call("messages", method: "GET", parameters)
    }

    public func streams() async throws -> JSONObject {
        try await call("streams", method: "GET", ["include_public": true, "include_subscribed": true])
    }

    /// Form values as the Python client sends them: strings as they are,
    /// anything else as JSON.
    static func encode(_ parameters: [String: any Sendable]) -> [URLQueryItem] {
        parameters.keys.sorted().map { key in
            let value = parameters[key]!
            if let text = value as? String {
                return URLQueryItem(name: key, value: text)
            }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return URLQueryItem(name: key, value: String(decoding: data, as: UTF8.self))
        }
    }

    func request(_ endpoint: String, method: String, _ parameters: [String: any Sendable], timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: credentials.baseURL.appendingPathComponent("v1/" + endpoint), resolvingAgainstBaseURL: false)!
        var form = URLComponents()
        form.queryItems = Self.encode(parameters)
        // URLComponents leaves "+" alone, which a server reads as a space.
        let encoded = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        var request: URLRequest
        if method == "GET" {
            components.percentEncodedQuery = encoded.isEmpty ? nil : encoded
            request = URLRequest(url: components.url!)
        } else {
            request = URLRequest(url: components.url!)
            request.httpBody = Data(encoded.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("z-iris (Darwin; \(ProcessInfo.processInfo.operatingSystemVersionString))", forHTTPHeaderField: "User-Agent")
        return request
    }

    func call(_ endpoint: String, method: String, _ parameters: [String: any Sendable], longPolling: Bool = false) async throws -> JSONObject {
        var parameters = parameters
        var failures = 0
        while true {
            let request = request(endpoint, method: method, parameters, timeout: longPolling ? 90 : 15)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .timedOut && longPolling {
                // The long-poll is expected to time out; ask again.
                continue
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                guard lock.withLock({ connected }), failures < 10 else {
                    throw ZulipClientError(description: "cannot connect to server \(credentials.baseURL.absoluteString)")
                }
                failures += 1
                parameters["dont_block"] = true
                try await Task.sleep(for: .seconds(1))
                continue
            }
            lock.withLock { connected = true }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (500..<600).contains(status), failures < 10 {
                failures += 1
                parameters["dont_block"] = true
                try await Task.sleep(for: .seconds(1))
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return JSONObject(["msg": "Unexpected error from the server", "result": "http-error", "status_code": status])
            }
            return JSONObject(object)
        }
    }
}

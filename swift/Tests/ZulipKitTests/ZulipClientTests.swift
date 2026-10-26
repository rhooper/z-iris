import Foundation
import Testing
@testable import ZulipKit

/// Answers requests from a handler registered for the request's host, so
/// tests running at the same time keep apart.
final class Stub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func on(_ host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            seen[host] = []
        }
    }

    static func requests(_ host: String) -> [URLRequest] { lock.withLock { seen[host] ?? [] } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = body
        }
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[host, default: []].append(request)
            return Self.handlers[host]
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Suite struct ZuliprcTests {
    private func write(_ text: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zuliprc-\(UUID().uuidString)").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test(arguments: [
        ("chat.example.com", "https://chat.example.com/api/"),
        ("https://chat.example.com/", "https://chat.example.com/api/"),
        ("https://chat.example.com/api", "https://chat.example.com/api/"),
        ("https://chat.example.com/api///", "https://chat.example.com/api/"),
        ("localhost:9991", "http://localhost:9991/api/"),
        ("http://zulip.lan/sub", "http://zulip.lan/sub/api/"),
    ])
    func baseURL(site: String, expected: String) {
        #expect(Credentials.baseURL(site: site) == expected)
    }

    @Test func readsTheAPISection() throws {
        let path = try write("""
        ; comment
        [other]
        key = nope
        [api]
        email=ada@example.com
        KEY : abc123
        site = chat.example.com
        """)
        let credentials = try Zuliprc.load(path: path, environment: [:])
        #expect(credentials.email == "ada@example.com")
        #expect(credentials.key == "abc123")
        #expect(credentials.baseURL.absoluteString == "https://chat.example.com/api/")
        #expect(credentials.host == "chat.example.com")
    }

    @Test func environmentWinsAsInThePythonClient() throws {
        let path = try write("[api]\nemail=a@x\nkey=k\nsite=one.example\n")
        let credentials = try Zuliprc.load(path: path, environment: ["ZULIP_SITE": "two.example"])
        #expect(credentials.host == "two.example")
    }

    @Test func theKeyNeverShows() throws {
        let path = try write("[api]\nemail=a@x\nkey=SECRETKEY\nsite=one.example\n")
        let credentials = try Zuliprc.load(path: path, environment: [:])
        #expect(!"\(credentials)".contains("SECRETKEY"))
        #expect(!String(reflecting: credentials).contains("SECRETKEY"))
    }

    @Test func missingParts() throws {
        #expect(throws: ZuliprcError.self) { try Zuliprc.load(path: "/nonexistent/zuliprc", environment: [:]) }
        let noSite = try write("[api]\nemail=a@x\nkey=k\n")
        #expect(throws: ZuliprcError.self) { try Zuliprc.load(path: noSite, environment: [:]) }
    }
}

@Suite struct ZulipClientTests {
    private func client(_ host: String) -> ZulipClient {
        ZulipClient(credentials: try! Credentials(email: "a@x", key: "k", site: host), session: Stub.session)
    }

    @Test func registerPostsAFormWithJSONValues() async throws {
        Stub.on("register.test") { _ in (200, [:], json(["result": "success", "queue_id": "q"])) }
        let reply = try await client("register.test").register(eventTypes: ["message", "x+y"], applyMarkdown: false, clientGravatar: false)
        #expect(reply.succeeded)
        let request = Stub.requests("register.test")[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://register.test/api/v1/register")
        #expect(form(request) == ["event_types": "[\"message\",\"x+y\"]", "apply_markdown": "false", "client_gravatar": "false"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("a@x:k".utf8).base64EncodedString())
    }

    @Test func getPutsParametersInTheQuery() async throws {
        Stub.on("get.test") { _ in (200, [:], json(["result": "success", "messages": [Any]()])) }
        _ = try await client("get.test").messages([
            "anchor": "newest", "num_before": 1000, "apply_markdown": false,
            "narrow": [["operator": "is", "operand": "mentioned"]],
        ])
        let request = Stub.requests("get.test")[0]
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/messages")
        let items = query(request)
        #expect(items["anchor"] == "newest")
        #expect(items["num_before"] == "1000")
        #expect(items["apply_markdown"] == "false")
        let narrow = try JSONSerialization.jsonObject(with: Data(items["narrow"]!.utf8)) as? [[String: String]]
        #expect(narrow == [["operator": "is", "operand": "mentioned"]])
        #expect(request.url?.absoluteString.contains("+") == false)
    }

    @Test func aServerErrorIsRetriedWithDontBlock() async throws {
        let attempts = Counter()
        Stub.on("retry.test") { _ in
            attempts.increment() == 1 ? (502, [:], Data("bad gateway".utf8)) : (200, [:], json(["result": "success"]))
        }
        let reply = try await client("retry.test").profile()
        #expect(reply.succeeded)
        let requests = Stub.requests("retry.test")
        #expect(requests.count == 2)
        #expect(query(requests[1])["dont_block"] == "true")
    }

    @Test func aReplyThatIsNotJSONIsAnHTTPError() async throws {
        Stub.on("html.test") { _ in (404, [:], Data("<html>".utf8)) }
        let reply = try await client("html.test").profile()
        #expect(reply["result"] as? String == "http-error")
        #expect(reply["status_code"] as? Int == 404)
    }

    @Test func aServerNeverReachedIsNotRetried() async throws {
        let api = client("unreachable.test")  // no handler: cannot connect
        await #expect(throws: ZulipClientError.self) { _ = try await api.profile() }
        #expect(Stub.requests("unreachable.test").count == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

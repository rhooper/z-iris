import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZIrisCore
@testable import ZulipKit

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x30, count: 20)
private let basicAuth = "Basic " + Data("bot@example.com:SECRETKEY".utf8).base64EncodedString()

/// Answers from a url -> reply map and records each request.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case ok(String, Data)
        case response(Int, [String: String], [Data])
        case failure(Error)
    }

    private let lock = NSLock()
    private var routes: [String: Reply]
    private var recorded: [(url: String, authorization: String?, timeout: Double)] = []
    var onGet: (@Sendable () -> Void)?

    init(_ routes: [String: Reply] = [:], route: ((String) -> Reply?)? = nil) {
        self.routes = routes
        self.fallback = route
    }

    private let fallback: ((String) -> Reply?)?

    var calls: [(url: String, authorization: String?, timeout: Double)] { lock.withLock { recorded } }

    func get(_ url: String, authorization: String?, timeout: Double) async throws -> HTTPResponse {
        let reply = lock.withLock { () -> Reply? in
            recorded.append((url, authorization, timeout))
            return routes[url] ?? fallback?(url)
        }
        onGet?()
        let (status, headers, chunks): (Int, [String: String], [Data])
        switch reply {
        case nil: (status, headers, chunks) = (404, [:], [])
        case let .ok(type, body)?: (status, headers, chunks) = (200, ["Content-Type": type], [body])
        case let .response(code, fields, parts)?: (status, headers, chunks) = (code, fields, parts)
        case let .failure(error)?: throw error
        }
        return HTTPResponse(status: status, headers: headers, body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        })
    }
}

private struct FakeClient: ZulipAPI {
    let credentials = try! Credentials(email: "bot@example.com", key: "SECRETKEY", site: "https://chat.example.com/")
    func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject { JSONObject([:]) }
    func events(queueID: String, lastEventID: Int) async throws -> JSONObject { JSONObject([:]) }
    func deregister(queueID: String) async throws -> JSONObject { JSONObject([:]) }
    func profile() async throws -> JSONObject { JSONObject([:]) }
    func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject { JSONObject([:]) }
    func streams() async throws -> JSONObject { JSONObject([:]) }
}

private func message(_ content: String = "hi", avatar: String? = nil, server: String = "main") -> Message {
    Message(server: server, host: "chat.example.com", id: 1, kind: .dm, senderID: 2, senderName: "A",
            content: content, flags: [], channelID: nil, channelName: nil, topic: nil, dmUserIDs: [2],
            avatarURL: avatar)
}

private func copyConvert(_ source: URL, _ destination: URL, _ pixels: Int) -> Bool {
    (try? FileManager.default.copyItem(at: source, to: destination)) != nil
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-media-\(UUID().uuidString)")
}

private func resolver(
    _ net: FakeTransport, client: Bool = true, external: Bool = true, cacheCap: Int = 50 << 20,
    maxImageBytes: Int = 8 << 20, timeout: Double = 4,
    convert: @escaping @Sendable (URL, URL, Int) -> Bool = copyConvert,
    now: @escaping @Sendable () -> Double = monotonicNow, directory: URL = temporaryDirectory()
) -> ImageResolver {
    ImageResolver(
        clients: { $0 == "main" && client ? FakeClient() : nil }, cacheDirectory: directory, transport: net,
        convert: convert, externalImages: { external }, timeout: timeout, maxImageBytes: maxImageBytes,
        cacheCapBytes: cacheCap, now: now
    )
}

@Suite struct ResolverTests {
    @Test func externalImageGetsNoCredentials() async throws {
        let net = FakeTransport(["https://x.com/a.png": .ok("image/png", png)])
        let path = try #require(await resolver(net).image(for: message("![p](https://x.com/a.png)")))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        #expect(net.calls[0].authorization == nil)
    }

    @Test func credentialsNeverGoToAForeignHost() async {
        let net = FakeTransport([
            "https://evil.example.org/chat.example.com/a.png": .ok("image/png", png),
            "https://chat.example.com.evil.org/a.png": .ok("image/png", png),
        ])
        let r = resolver(net)
        _ = await r.image(for: message("![p](https://evil.example.org/chat.example.com/a.png)"))
        _ = await r.image(for: message("![p](https://chat.example.com.evil.org/a.png)"))
        #expect(!net.calls.isEmpty && net.calls.allSatisfy { $0.authorization == nil })
    }

    @Test func aRelativeUploadUsesCredentialsOnTheServer() async {
        let url = "https://chat.example.com/user_uploads/1/ab/cat.png"
        let net = FakeTransport([url: .ok("image/png", png)])
        #expect(await resolver(net).image(for: message("[c](/user_uploads/1/ab/cat.png)")) != nil)
        #expect(net.calls[0].url == url)
        #expect(net.calls[0].authorization == basicAuth)
    }

    @Test func anAbsoluteUploadOnTheServerUsesCredentials() async {
        let url = "https://chat.example.com/user_uploads/1/ab/cat.png"
        let net = FakeTransport([url: .ok("image/png", png)])
        _ = await resolver(net).image(for: message("![c](\(url))"))
        #expect(net.calls[0].authorization == basicAuth)
    }

    @Test func aRelativeThumbnail() async {
        let url = "https://chat.example.com/thumbnail?url=user_uploads%2F1%2Fa.png&size=full"
        let net = FakeTransport([url: .ok("image/png", png)])
        #expect(await resolver(net).image(for: message("![t](/thumbnail?url=user_uploads%2F1%2Fa.png&size=full)")) != nil)
        #expect(net.calls[0].authorization != nil)
    }

    @Test func aRelativeURLWithoutAClientIsSkipped() async {
        let net = FakeTransport()
        #expect(await resolver(net, client: false).image(for: message("[c](/user_uploads/1/ab/cat.png)")) == nil)
        #expect(net.calls.isEmpty)
    }

    @Test func avatars() async {
        let net = FakeTransport([
            "https://cdn.x.com/av.png": .ok("image/png", png),
            "https://chat.example.com/user_avatars/1.png": .ok("image/png", png),
        ])
        let r = resolver(net)
        #expect(await r.image(for: message("no image", avatar: "https://cdn.x.com/av.png")) != nil)
        #expect(net.calls[0].authorization == nil)
        #expect(await r.image(for: message("x", avatar: "/user_avatars/1.png")) != nil)
        #expect(await r.image(for: message("x")) == nil)
    }

    @Test func aFailedImageFallsBackToTheAvatar() async {
        let net = FakeTransport(["https://cdn.x.com/av.png": .ok("image/png", png)])
        #expect(await resolver(net).image(for: message("![p](https://x.com/missing.png)", avatar: "https://cdn.x.com/av.png")) != nil)
    }

    @Test func failuresGiveNil() async {
        let cases: [(String, FakeTransport.Reply)] = [
            ("https://x.com/a.png", .failure(URLError(.timedOut))),
            ("https://x.com/a.png", .ok("text/html", Data("<html>".utf8))),
            ("https://x.com/a.svg", .ok("image/svg+xml", Data("<svg/>".utf8))),
        ]
        for (url, reply) in cases {
            let net = FakeTransport([url: reply])
            #expect(await resolver(net).image(for: message("![p](\(url))")) == nil)
        }
    }

    @Test func webpIsConvertedAtThePictureSize() async throws {
        let seen = Counter()
        let net = FakeTransport(["https://x.com/a.webp": .ok("image/webp", Data("RIFFxxxxWEBP".utf8))])
        let r = resolver(net, convert: { _, destination, pixels in
            #expect(pixels == 512)
            seen.increment()
            return (try? png.write(to: destination)) != nil
        })
        let path = try #require(await r.image(for: message("![p](https://x.com/a.webp)")))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        #expect(seen.increment() == 2)
    }

    @Test func aFailedConversionGivesNil() async {
        let net = FakeTransport(["https://x.com/a.png": .ok("image/png", png)])
        #expect(await resolver(net, convert: { _, _, _ in false }).image(for: message("![p](https://x.com/a.png)")) == nil)
    }

    @Test func theSizeCapAndTimeoutApply() async {
        let net = FakeTransport(["https://x.com/a.png": .ok("image/png", Data(count: 2000))])
        #expect(await resolver(net, maxImageBytes: 1234, timeout: 2.5).image(for: message("![p](https://x.com/a.png)")) == nil)
        #expect(net.calls[0].timeout == 2.5)
    }

    @Test func aCacheHitFetchesOnce() async {
        let net = FakeTransport(["https://x.com/a.png": .ok("image/png", png)])
        let r = resolver(net)
        let a = await r.image(for: message("![p](https://x.com/a.png)"))
        let b = await r.image(for: message("![p](https://x.com/a.png)"))
        #expect(a != nil && a == b && net.calls.count == 1)
    }

    @Test func theCacheIsKeyedPerServer() async {
        let net = FakeTransport(["https://chat.example.com/user_uploads/a.png": .ok("image/png", png)])
        let r = resolver(net)
        _ = await r.image(for: message("[c](/user_uploads/a.png)", server: "main"))
        #expect(await r.image(for: message("[c](/user_uploads/a.png)", server: "other")) == nil)
    }

    @Test func theCacheIsPrunedToItsCap() async throws {
        let net = FakeTransport(route: { _ in .ok("image/png", png) })
        let directory = temporaryDirectory()
        let r = resolver(net, cacheCap: png.count * 2, directory: directory)
        for index in 0..<5 {
            let path = try #require(await r.image(for: message("![p](https://x.com/\(index).png)")))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(index))], ofItemAtPath: path)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        #expect(files.count <= 2)
    }

    @Test func imageAndAvatarShareOneBudget() async {
        let clock = Clock()
        let net = FakeTransport(["https://x.com/a.png": .failure(URLError(.timedOut))])
        net.onGet = { clock.advance(9) }  // the image attempt eats the whole budget
        let r = resolver(net, now: { clock.now })
        #expect(await r.image(for: message("![p](https://x.com/a.png)", avatar: "https://x.com/av.png")) == nil)
        #expect(net.calls.count == 1)
    }

    @Test func externalImagesOff() async {
        let upload = "https://chat.example.com/user_uploads/1/a/x.png"
        let gravatar = "https://secure.gravatar.com/avatar/abc"
        let serverAvatar = "https://chat.example.com/avatar/5"
        let storage = "https://zulip-avatars.s3.amazonaws.com/2/abc.png"
        let net = FakeTransport([
            "https://x.com/a.png": .ok("image/png", png), upload: .ok("image/png", png),
            gravatar: .ok("image/png", png), serverAvatar: .ok("image/png", png), storage: .ok("image/png", png),
        ])
        let r = resolver(net, external: false)
        #expect(await r.image(for: message("![p](https://x.com/a.png)")) == nil)
        #expect(net.calls.isEmpty)
        #expect(await r.image(for: message("![p](\(upload))")) != nil)
        #expect(await r.image(for: message("hi", avatar: gravatar)) != nil)
        #expect(await r.image(for: message("hi", avatar: serverAvatar)) != nil)
        #expect(await r.images(for: message("x", avatar: storage)).avatar != nil)
        #expect(net.calls.filter { $0.url != upload }.allSatisfy { $0.authorization == nil })
    }

    @Test func imagesComeBackSeparately() async {
        let net = FakeTransport(["https://x.com/a.png": .ok("image/png", png), "https://cdn.x.com/av.png": .ok("image/png", png)])
        let r = resolver(net)
        let both = await r.images(for: message("![p](https://x.com/a.png)", avatar: "https://cdn.x.com/av.png"))
        #expect(both.picture != nil && both.avatar != nil && both.picture != both.avatar)
        let avatarOnly = await r.images(for: message("no image", avatar: "https://cdn.x.com/av.png"))
        #expect(avatarOnly.picture == nil && avatarOnly.avatar != nil)
        let m = message("![p](https://x.com/a.png)", avatar: "https://cdn.x.com/av.png")
        #expect(await r.image(for: m) == both.picture)
    }

    @Test func theRealConverterScalesAsSipsDoes() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("small.png")
        // A 10x6 PNG written with ImageIO.
        let context = CGContext(data: nil, width: 10, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let out = directory.appendingPathComponent("out.png")
        #expect(convertImage(source, out, maxPixels: 256))
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil)!
        #expect((image.width, image.height) == (256, 153))
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    var now: Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

@Suite struct HTTPGetTests {
    @Test func anUnsupportedSchemeIsRefused() async {
        await #expect(throws: HTTPError.self) {
            try await httpGet("file:///etc/passwd", timeout: 1, maxBytes: 10, transport: FakeTransport())
        }
    }

    @Test func theSizeCapHolds() async {
        let chunked = FakeTransport(["https://x.com/a": .response(200, ["content-type": "image/png"], [Data(count: 6), Data(count: 6)])])
        await #expect(throws: HTTPError(description: "too large")) {
            try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, transport: chunked)
        }
        let declared = FakeTransport(["https://x.com/a": .response(200, ["content-type": "image/png", "content-length": "999"], [Data("abc".utf8)])])
        await #expect(throws: HTTPError(description: "too large")) {
            try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, transport: declared)
        }
    }

    @Test func aRedirectToAForeignHostDropsCredentials() async throws {
        let net = FakeTransport([
            "https://chat.example.com/user_uploads/1/a/x.png": .response(302, ["Location": "https://cdn.other.com/x.png"], []),
            "https://cdn.other.com/x.png": .ok("image/png", Data("abc".utf8)),
        ])
        let credentials = FakeClient().credentials
        let (_, body) = try await httpGet("https://chat.example.com/user_uploads/1/a/x.png", credentials: credentials,
                                          authBase: "https://chat.example.com/", timeout: 1, maxBytes: 100, transport: net)
        #expect(body == Data("abc".utf8))
        #expect(net.calls[0].authorization == basicAuth)
        #expect(net.calls[1].authorization == nil)
    }

    @Test func aDowngradeOrAnotherPathDropsCredentials() async throws {
        let credentials = FakeClient().credentials
        let downgrade = FakeTransport([
            "https://chat.example.com/user_uploads/1/a/x.png": .response(302, ["location": "http://chat.example.com/user_uploads/1/a/x.png"], []),
            "http://chat.example.com/user_uploads/1/a/x.png": .ok("image/png", png),
        ])
        _ = try await httpGet("https://chat.example.com/user_uploads/1/a/x.png", credentials: credentials,
                              authBase: "https://chat.example.com/", timeout: 1, maxBytes: 100, transport: downgrade)
        #expect(downgrade.calls[0].authorization == basicAuth && downgrade.calls[1].authorization == nil)

        let elsewhere = FakeTransport([
            "https://chat.example.com/user_uploads/1/a/x.png": .response(302, ["location": "/json/users/me"], []),
            "https://chat.example.com/json/users/me": .ok("image/png", png),
        ])
        _ = try await httpGet("https://chat.example.com/user_uploads/1/a/x.png", credentials: credentials,
                              authBase: "https://chat.example.com/", timeout: 1, maxBytes: 100, transport: elsewhere)
        #expect(elsewhere.calls[1].authorization == nil)
    }

    @Test func badRedirectsAndLoops() async {
        let badScheme = FakeTransport(route: { _ in .response(302, ["location": "ftp://x/a"], []) })
        await #expect(throws: HTTPError.self) { try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, transport: badScheme) }
        let loop = FakeTransport(route: { _ in .response(302, ["location": "https://x.com/a"], []) })
        await #expect(throws: HTTPError(description: "too many redirects")) {
            try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, transport: loop)
        }
        #expect(loop.calls.count == 4)
    }

    @Test func anErrorStatusFails() async {
        await #expect(throws: HTTPError(description: "status 404")) {
            try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, transport: FakeTransport())
        }
    }

    @Test func thePastDeadlineStopsBeforeAnyHop() async {
        let net = FakeTransport(route: { _ in .response(302, ["location": "https://x.com/b"], []) })
        await #expect(throws: HTTPError(description: "too slow")) {
            try await httpGet("https://x.com/a", timeout: 1, maxBytes: 10, deadline: monotonicNow() - 1, transport: net)
        }
        #expect(net.calls.isEmpty)
    }

    @Test func thePruneSparesRecentFilesAndTheOneJustStored() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fresh = directory.appendingPathComponent("fresh.png")
        try Data(count: 100).write(to: fresh)
        let old = directory.appendingPathComponent("old.png")
        try Data(count: 100).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        // Storing a new image runs the prune.
        let r = resolver(FakeTransport(["https://x.com/n.png": .ok("image/png", png)]), cacheCap: 1, directory: directory)
        let stored = try #require(await r.image(for: message("![p](https://x.com/n.png)")))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: stored))
    }
}

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIrisCore

// Pick a local image for a notification: the first image in a message, and
// the sender's avatar (media.py). Every network step is bounded (timeouts,
// size caps, one time budget) and any failure yields nil. Zulip credentials
// are only ever sent to the server's own host, re-checked on every redirect.

public struct HTTPError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { $1 }
        self.body = body
    }
}

/// One GET that does not follow redirects.
public protocol HTTPTransport: Sendable {
    func get(_ url: String, authorization: String?, timeout: Double) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func get(_ url: String, authorization: String?, timeout: Double) async throws -> HTTPResponse {
        guard let target = URL(string: url) else { throw HTTPError(description: "bad url") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw HTTPError(description: "not http") }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { headers, field in
            headers[String(describing: field.key)] = String(describing: field.value)
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == 8192 {
                            continuation.yield(chunk)
                            chunk = Data()
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
}

public func monotonicNow() -> Double { ProcessInfo.processInfo.systemUptime }

/// GET with a size cap and a total deadline. Redirects are followed by hand;
/// credentials are re-checked on every hop against authBase and dropped for
/// good as soon as a hop fails the check. Without authBase none are sent.
public func httpGet(
    _ url: String, credentials: Credentials? = nil, authBase: String? = nil, timeout: Double,
    maxBytes: Int, deadline: Double? = nil, maxRedirects: Int = 3,
    transport: any HTTPTransport, now: @Sendable () -> Double = monotonicNow
) async throws -> (contentType: String, body: Data) {
    let deadline = deadline ?? now() + timeout * 2
    var url = url
    var credentials = credentials
    for _ in 0...maxRedirects {
        if now() > deadline { throw HTTPError(description: "too slow") }
        let scheme = PyURL(url).scheme.lowercased()
        if scheme != "http", scheme != "https" { throw HTTPError(description: "unsupported scheme") }
        var send: String?
        if let given = credentials, let authBase, credentialsAllowed(url, base: authBase) {
            send = given.authorization
        } else {
            credentials = nil  // once dropped, never sent again
        }
        let response: HTTPResponse
        do {
            response = try await transport.get(url, authorization: send, timeout: timeout)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError(description: String(describing: type(of: error)))
        }
        if [301, 302, 303, 307, 308].contains(response.status) {
            guard let location = response.headers["location"], !location.isEmpty else {
                throw HTTPError(description: "redirect without location")
            }
            url = pyURLJoin(url, location)
            continue
        }
        if response.status != 200 { throw HTTPError(description: "status \(response.status)") }
        if let declared = response.headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           declared > maxBytes {
            throw HTTPError(description: "too large")
        }
        var body = Data()
        do {
            for try await chunk in response.body {
                body.append(chunk)
                if body.count > maxBytes { throw HTTPError(description: "too large") }
                if now() > deadline { throw HTTPError(description: "too slow") }
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError(description: String(describing: type(of: error)))
        }
        let contentType = (response.headers["content-type"] ?? "").split(separator: ";", maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return (contentType, body)
    }
    throw HTTPError(description: "too many redirects")
}

/// Write src as a PNG whose longest side is maxPixels, as `sips -Z` does
/// (small images are scaled up too).
public func convertImage(_ source: URL, _ destination: URL, maxPixels: Int) -> Bool {
    guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return false }
    let longest = Double(max(image.width, image.height))
    guard longest > 0 else { return false }
    let scale = Double(maxPixels) / longest
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(output, scaled, nil)
    return CGImageDestinationFinalize(output)
}

public func defaultCacheDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/z-iris/media")
}

public final class ImageResolver: Sendable {
    private let clients: @Sendable (String) -> (any ZulipAPI)?
    let cacheDirectory: URL
    private let transport: any HTTPTransport
    private let convert: @Sendable (URL, URL, Int) -> Bool
    private let externalImages: @Sendable () -> Bool
    private let now: @Sendable () -> Double
    private let pruneLock = NSLock()
    let timeout: Double
    let maxImageBytes: Int
    let maxAvatarBytes: Int
    let cacheCapBytes: Int
    let imagePixels: Int
    let avatarPixels: Int
    let totalBudget: Double

    public init(
        clients: @escaping @Sendable (String) -> (any ZulipAPI)?,
        cacheDirectory: URL = defaultCacheDirectory(),
        transport: any HTTPTransport = URLSessionTransport(),
        convert: @escaping @Sendable (URL, URL, Int) -> Bool = { convertImage($0, $1, maxPixels: $2) },
        externalImages: @escaping @Sendable () -> Bool = { false },
        timeout: Double = 4, maxImageBytes: Int = 8 << 20, maxAvatarBytes: Int = 1 << 20,
        cacheCapBytes: Int = 50 << 20, imagePixels: Int = 512, avatarPixels: Int = 256,
        totalBudget: Double = 8, now: @escaping @Sendable () -> Double = monotonicNow
    ) {
        self.clients = clients
        self.cacheDirectory = cacheDirectory
        self.transport = transport
        self.convert = convert
        self.externalImages = externalImages
        self.timeout = timeout
        self.maxImageBytes = maxImageBytes
        self.maxAvatarBytes = maxAvatarBytes
        self.cacheCapBytes = cacheCapBytes
        self.imagePixels = imagePixels
        self.avatarPixels = avatarPixels
        self.totalBudget = totalBudget
        self.now = now
    }

    /// Both images, within one shared time budget. Never fails.
    public func images(for message: Message) async -> MessageImages {
        let client = clients(message.server)
        let deadline = now() + totalBudget
        var picture: String?
        if let url = extractImageURLs(message.content).first {
            picture = await fetch(message.server, client, url, maxImageBytes, imagePixels, deadline)
        }
        var avatar: String?
        if let url = message.avatarURL, now() < deadline {
            avatar = await fetch(message.server, client, url, maxAvatarBytes, avatarPixels, deadline, avatar: true)
        }
        return MessageImages(avatar: avatar, picture: picture)
    }

    /// One image: the message's own picture, else the sender's avatar.
    public func image(for message: Message) async -> String? {
        let images = await images(for: message)
        return images.picture ?? images.avatar
    }

    func cacheFile(_ server: String, _ absolute: String) -> URL {
        let digest = SHA256.hash(data: Data("\(server)\n\(absolute)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(String(digest.prefix(32)) + ".png")
    }

    private func fetch(_ server: String, _ client: (any ZulipAPI)?, _ url: String, _ maxBytes: Int,
                       _ maxPixels: Int, _ deadline: Double, avatar: Bool = false) async -> String? {
        let base = client?.credentials.baseURL.absoluteString
        let absolute: String
        if !PyURL(url).scheme.isEmpty {
            absolute = url
        } else if let base {
            absolute = pyURLJoin(base, url)
        } else {
            return nil  // relative, and no server to resolve it against
        }
        let scheme = PyURL(absolute).scheme.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let final = cacheFile(server, absolute)
        if FileManager.default.fileExists(atPath: final.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: final.path)
            return final.path
        }
        if now() >= deadline { return nil }
        var credentials: Credentials?
        if let base, credentialsAllowed(absolute, base: base) {
            credentials = client?.credentials
        } else if let base, sameOrigin(absolute, base) {
            if !avatar {
                return nil  // the server's own host, but not a media path
            }
            // Server avatars such as /avatar/<id> are public: no credentials.
        } else if !(externalImages() || avatar) {
            // A message's own picture can point anywhere its sender likes, and
            // that host would see this machine's address. An avatar URL is set
            // by the server (its storage, or Gravatar), so it is fetched,
            // without credentials.
            return nil
        }
        do {
            let (contentType, body) = try await httpGet(
                absolute, credentials: credentials, authBase: credentials == nil ? nil : base,
                timeout: timeout, maxBytes: maxBytes, deadline: deadline, transport: transport, now: now
            )
            guard contentType.hasPrefix("image/"), !contentType.contains("svg") else { return nil }
            return store(body, final, maxPixels)
        } catch {
            return nil
        }
    }

    private func store(_ body: Data, _ final: URL, _ maxPixels: Int) -> String? {
        let files = FileManager.default
        try? files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let raw = cacheDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        let out = raw.deletingPathExtension().appendingPathExtension("tmp.png")
        defer {
            try? files.removeItem(at: raw)
            try? files.removeItem(at: out)
        }
        guard (try? body.write(to: raw)) != nil, convert(raw, out, maxPixels), files.fileExists(atPath: out.path) else {
            return nil
        }
        _ = try? files.removeItem(at: final)
        guard (try? files.moveItem(at: out, to: final)) != nil else { return nil }
        prune(keeping: final)
        return final.path
    }

    private func prune(keeping keep: URL) {
        pruneLock.withLock {
            let files = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let entries = ((try? files.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys)) ?? [])
                .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasSuffix(".tmp.png") }
                .compactMap { url -> (Date, URL, Int)? in
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          let date = values.contentModificationDate else { return nil }
                    return (date, url, values.fileSize ?? 0)
                }
            var total = entries.reduce(0) { $0 + $1.2 }
            let recent = Date().addingTimeInterval(-60)  // may be in use by a notification right now
            for (date, url, size) in entries.sorted(by: { $0.0 < $1.0 }) {
                if total <= cacheCapBytes { break }
                if url.standardizedFileURL == keep.standardizedFileURL || date > recent { continue }
                try? files.removeItem(at: url)
                total -= size
            }
        }
    }
}

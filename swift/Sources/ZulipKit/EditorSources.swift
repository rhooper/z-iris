import Foundation
import ZIrisCore

// What the rules editor fetches: every channel busiest first (channels.py),
// and recent messages to preview a draft against (preview.py).

/// Channel names by weekly traffic, busiest first, then by name.
public func busiest(_ traffic: [String: Int]) -> [String] {
    traffic.keys.sorted { a, b in
        traffic[a]! != traffic[b]! ? traffic[a]! > traffic[b]! : pythonOrder(a.pythonLowercased, b.pythonLowercased)
    }
}

public struct ServerChannels: Sendable, Equatable {
    public var name: String
    public var channels: [String]
    public var error: String?
}

/// Every channel the user can see on each server, cached for five minutes.
/// Busy means Zulip's stream_weekly_traffic.
public actor ChannelSource {
    private let client: @Sendable (ServerConfig) throws -> any ZulipAPI
    private let now: @Sendable () -> Double
    private let ttl: Double
    private var cache: [String: (taken: Double, traffic: [String: Int])] = [:]

    public init(client: @escaping @Sendable (ServerConfig) throws -> any ZulipAPI = { try ZulipClient(zuliprc: $0.zuliprc) },
                now: @escaping @Sendable () -> Double = monotonicNow, ttl: Double = 300) {
        self.client = client
        self.now = now
        self.ttl = ttl
    }

    private func traffic(_ server: ServerConfig) async throws -> [String: Int] {
        if let cached = cache[server.name], now() - cached.taken < ttl {
            return cached.traffic
        }
        let reply = try await client(server).streams()
        guard reply.succeeded, let streams = reply["streams"] as? [[String: Any]] else {
            throw ZulipClientError(description: reply.message(or: "could not fetch channels"))
        }
        var traffic: [String: Int] = [:]
        for stream in streams {
            if let name = stream["name"] as? String {
                traffic[name] = (stream["stream_weekly_traffic"] as? NSNumber)?.intValue ?? 0
            }
        }
        cache[server.name] = (now(), traffic)
        return traffic
    }

    /// Each server's channels, and all of them together (a channel counting
    /// its busiest server).
    public func channels(_ servers: [ServerConfig]) async -> (servers: [ServerChannels], all: [String]) {
        var entries: [ServerChannels] = []
        var everything: [String: Int] = [:]
        for server in servers {
            do {
                let traffic = try await traffic(server)
                entries.append(ServerChannels(name: server.name, channels: busiest(traffic)))
                everything.merge(traffic) { max($0, $1) }
            } catch {
                entries.append(ServerChannels(name: server.name, channels: [], error: "\(error)"))
            }
        }
        return (entries, busiest(everything))
    }
}

public let previewFetchCount = 1000
public let previewMentionCount = 50
public let previewMaxMessages = 10_000

public struct ServerPreview: Sendable {
    public var name: String
    public var fetched: Int
    /// The oldest message on the server is included.
    public var complete: Bool
    public var messages: [PreviewEntry]
    public var error: String?
}

/// Fetches recent messages once per server, then evaluates any draft config
/// against them. Older pages are added on request.
public actor PreviewSource {
    private struct Snapshot {
        var taken: Double
        var host: String
        var selfID: Int
        var mutes: MuteState
        var messages: [JSONObject]
        var complete: Bool
        var windowOldest: Int?
    }

    private let client: @Sendable (ServerConfig) throws -> any ZulipAPI
    private let now: @Sendable () -> Double
    private let ttl: Double
    private var cache: [String: Snapshot] = [:]

    public init(client: @escaping @Sendable (ServerConfig) throws -> any ZulipAPI = { try ZulipClient(zuliprc: $0.zuliprc) },
                now: @escaping @Sendable () -> Double = monotonicNow, ttl: Double = 60) {
        self.client = client
        self.now = now
        self.ttl = ttl
    }

    private static func ids(_ messages: [Any]) -> [(Int, [String: Any])] {
        messages.compactMap { item in
            guard let message = item as? [String: Any], let id = (message["id"] as? NSNumber)?.intValue else { return nil }
            return (id, message)
        }
    }

    private func fetch(_ server: ServerConfig) async throws -> Snapshot {
        let api = try client(server)
        let registered = try await api.register(eventTypes: ["subscription", "user_topic", "muted_topics"],
                                                applyMarkdown: false, clientGravatar: false)
        guard registered.succeeded else {
            throw ZulipClientError(description: registered.message(or: "register failed"))
        }
        let mutes = try? MuteState(register: registered.value)
        if let queue = registered["queue_id"] as? String {
            _ = try? await api.deregister(queueID: queue)
        }
        guard let mutes else { throw ZulipClientError(description: "malformed register reply") }
        let profile = try await api.profile()
        guard profile.succeeded, let selfID = (profile["user_id"] as? NSNumber)?.intValue else {
            throw ZulipClientError(description: profile.message(or: "could not fetch own profile"))
        }
        let reply = try await api.messages([
            "anchor": "newest", "num_before": previewFetchCount, "num_after": 0, "apply_markdown": false,
        ])
        guard reply.succeeded else {
            throw ZulipClientError(description: reply.message(or: "could not fetch messages"))
        }
        var messages = Dictionary(Self.ids(reply["messages"] as? [Any] ?? []), uniquingKeysWith: { $1 })
        let windowOldest = messages.keys.min()
        // Mentions are rare, so the recent window may hold none. Fetch the
        // latest ones separately so a mention rule has something to show.
        if let mentioned = try? await api.messages([
            "anchor": "newest", "num_before": previewMentionCount, "num_after": 0, "apply_markdown": false,
            "narrow": [["operator": "is", "operand": "mentioned"]],
        ]), mentioned.succeeded {
            for (id, message) in Self.ids(mentioned["messages"] as? [Any] ?? []) where messages[id] == nil {
                messages[id] = message
            }
        }
        return Snapshot(
            taken: now(), host: api.credentials.host, selfID: selfID, mutes: mutes,
            messages: messages.keys.sorted().map { JSONObject(messages[$0]!) },
            complete: (reply["found_oldest"] as? Bool) ?? false, windowOldest: windowOldest
        )
    }

    /// One more page of older messages into the snapshot.
    private func older(_ server: ServerConfig, _ snapshot: inout Snapshot) async throws {
        if snapshot.complete || snapshot.messages.count >= previewMaxMessages {
            return
        }
        let anchor: any Sendable = snapshot.windowOldest.map { $0 as any Sendable } ?? "newest"
        let reply = try await client(server).messages([
            "anchor": anchor, "include_anchor": false, "num_before": previewFetchCount,
            "num_after": 0, "apply_markdown": false,
        ])
        guard reply.succeeded else {
            throw ZulipClientError(description: reply.message(or: "could not fetch messages"))
        }
        let page = Self.ids(reply["messages"] as? [Any] ?? [])
        let known = Set(snapshot.messages.compactMap { ($0["id"] as? NSNumber)?.intValue })
        let fresh = page.filter { !known.contains($0.0) }.map { JSONObject($0.1) }
        snapshot.messages = (snapshot.messages + fresh).sorted {
            (($0["id"] as? NSNumber)?.intValue ?? 0) < (($1["id"] as? NSNumber)?.intValue ?? 0)
        }
        if let oldest = page.map(\.0).min() {
            snapshot.windowOldest = oldest
        }
        snapshot.complete = ((reply["found_oldest"] as? Bool) ?? false) || page.isEmpty
    }

    private func snapshot(_ server: ServerConfig, refresh: Bool) async throws -> Snapshot {
        if let cached = cache[server.name], !refresh, now() - cached.taken < ttl {
            return cached
        }
        let fresh = try await fetch(server)
        cache[server.name] = fresh
        return fresh
    }

    /// Each server's recent messages with what the draft would do to them.
    public func preview(_ draft: Config, refresh: Bool = false, more: Bool = false) async -> [ServerPreview] {
        var servers: [ServerPreview] = []
        for server in draft.servers {
            var snapshot: Snapshot
            var problem: String?
            do {
                snapshot = try await self.snapshot(server, refresh: refresh && !more)
                if more {
                    do {
                        try await older(server, &snapshot)
                        cache[server.name] = snapshot
                    } catch {
                        problem = "\(error)"
                    }
                }
            } catch {
                servers.append(ServerPreview(name: server.name, fetched: 0, complete: false, messages: [], error: "\(error)"))
                continue
            }
            let pipeline = Pipeline(server: server.name, host: snapshot.host, selfID: snapshot.selfID,
                                    mutes: snapshot.mutes, config: { draft })
            servers.append(ServerPreview(
                name: server.name, fetched: snapshot.messages.count, complete: snapshot.complete,
                messages: previewEntries(snapshot.messages.map(\.value), pipeline: pipeline), error: problem
            ))
        }
        return servers
    }
}

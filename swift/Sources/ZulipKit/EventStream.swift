import Foundation
import ZIrisCore

// Stream events from one Zulip server into the engine: stream.py's
// ServerStream as an actor that runs until its task is cancelled.

public let eventTypes = [
    "message", "subscription", "user_topic", "muted_topics", "update_message_flags", "delete_message",
]

/// Where a stream sends what it hears. Engine is one.
public protocol EventSink: Sendable {
    func submit(_ notification: ZIrisCore.Notification) async
    func handle(server: String, _ event: ReadEvent) async
    func reconcileUnread(server: String, unread: Set<Int>) async
}

extension Engine: EventSink {}

/// Every unread message id in a register reply, or nil when the server did
/// not send them all (old servers, or too many unreads): then nothing may be
/// judged read.
public func unreadIDs(_ registered: [String: Any]) -> Set<Int>? {
    guard let unread = registered["unread_msgs"] as? [String: Any],
          !((unread["old_unreads_missing"] as? Bool) ?? false)
    else { return nil }
    func ints(_ value: Any?) -> [Int] {
        (value as? [Any])?.compactMap { item in
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !"df".contains(String(cString: number.objCType)) else { return nil }
            return number.intValue
        } ?? []
    }
    var ids = Set<Int>()
    for key in ["pms", "direct_message", "streams", "huddles"] {
        for case let entry as [String: Any] in (unread[key] as? [Any]) ?? [] {
            ids.formUnion(ints(entry["unread_message_ids"]))
        }
    }
    ids.formUnion(ints(unread["mentions"]))
    return ids
}

struct StreamError: Error, CustomStringConvertible {
    var description: String
}

public actor EventStream {
    public static let backoffStart = 1.0
    public static let backoffMax = 60.0

    private let server: String
    private let makeClient: @Sendable () throws -> any ZulipAPI
    private let sink: any EventSink
    private let config: @Sendable () -> Config
    private let status: @Sendable (String) -> Void
    private let sleep: @Sendable (Double) async throws -> Void
    private let onClient: @Sendable (any ZulipAPI) -> Void

    /// - Parameters:
    ///   - makeClient: a new client for each session (reads the zuliprc).
    ///   - status: the server's status line for the menubar.
    ///   - onClient: told each new client, for the media fetcher.
    public init(
        server: String,
        makeClient: @escaping @Sendable () throws -> any ZulipAPI,
        sink: any EventSink,
        config: @escaping @Sendable () -> Config,
        status: @escaping @Sendable (String) -> Void,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onClient: @escaping @Sendable (any ZulipAPI) -> Void = { _ in }
    ) {
        self.server = server
        self.makeClient = makeClient
        self.sink = sink
        self.config = config
        self.status = status
        self.sleep = sleep
        self.onClient = onClient
    }

    /// Stream until the task is cancelled, whatever happens.
    public func run() async {
        var backoff = Self.backoffStart
        status("connecting")
        while !Task.isCancelled {
            do {
                try await session()
                backoff = Self.backoffStart
            } catch {
                if Task.isCancelled { return }
                status("error: \(error)")
                do { try await sleep(backoff) } catch { return }
                backoff = min(backoff * 2, Self.backoffMax)
            }
        }
    }

    private func session() async throws {
        let client = try makeClient()
        onClient(client)
        let registered = try await client.register(eventTypes: eventTypes, applyMarkdown: false, clientGravatar: false)
        guard registered.succeeded else {
            throw StreamError(description: registered.message(or: "register failed"))
        }
        if let unread = unreadIDs(registered.value) {
            // Reads that happened while the old queue was dead never arrive.
            await sink.reconcileUnread(server: server, unread: unread)
        }
        let profile = try await client.profile()
        guard profile.succeeded, let selfID = profile["user_id"].flatMap({ ($0 as? NSNumber)?.intValue }) else {
            throw StreamError(description: profile.message(or: "could not fetch own profile"))
        }
        var pipeline = Pipeline(
            server: server, host: client.credentials.host, selfID: selfID,
            mutes: try MuteState(register: registered.value), config: config
        )
        guard let queueID = registered["queue_id"] as? String,
              var lastEventID = (registered["last_event_id"] as? NSNumber)?.intValue
        else { throw StreamError(description: "register reply has no queue") }
        status("connected")

        var backoff = Self.backoffStart
        while !Task.isCancelled {
            let response: JSONObject
            do {
                response = try await client.events(queueID: queueID, lastEventID: lastEventID)
            } catch {
                if Task.isCancelled { return }
                // A network drop. The queue stays alive on the server for a
                // while, so keep polling it to receive what was missed.
                status("reconnecting: \(error)")
                try await sleep(backoff)
                backoff = min(backoff * 2, Self.backoffMax)
                continue
            }
            backoff = Self.backoffStart
            guard response.succeeded else {
                if response["code"] as? String == "BAD_EVENT_QUEUE_ID" {
                    return  // the queue expired; register a new one
                }
                throw StreamError(description: response.message(or: "get_events failed"))
            }
            status("connected")
            for case let event as [String: Any] in (response["events"] as? [Any]) ?? [] {
                if let id = (event["id"] as? NSNumber)?.intValue {
                    lastEventID = max(lastEventID, id)
                }
                if let notification = pipeline.handle(event) {
                    await sink.submit(notification)
                } else if event["type"] as? String != "message", let read = ReadEvent(event) {
                    await sink.handle(server: server, read)
                }
            }
        }
    }
}

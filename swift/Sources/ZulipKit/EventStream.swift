import Foundation
import ZIrisCore

// Stream events from one Zulip server into the engine: stream.py's
// ServerStream as an actor that runs until its task is cancelled.

public let eventTypes = [
    "message", "subscription", "user_topic", "muted_topics", "update_message_flags", "delete_message",
    "reaction", "update_message", "realm_user",
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
    private let conversations: Conversations?

    /// - Parameters:
    ///   - makeClient: a new client for each session (reads the zuliprc).
    ///   - status: the server's status line for the menubar.
    ///   - onClient: told each new client, for the media fetcher.
    ///   - conversations: the topics you are in, shared by every server.
    public init(
        server: String,
        makeClient: @escaping @Sendable () throws -> any ZulipAPI,
        sink: any EventSink,
        config: @escaping @Sendable () -> Config,
        status: @escaping @Sendable (String) -> Void,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onClient: @escaping @Sendable (any ZulipAPI) -> Void = { _ in },
        conversations: Conversations? = nil
    ) {
        self.server = server
        self.makeClient = makeClient
        self.sink = sink
        self.config = config
        self.status = status
        self.sleep = sleep
        self.onClient = onClient
        self.conversations = conversations
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
            mutes: try MuteState(register: registered.value), config: config, conversations: conversations
        )
        var channelNames: [Int: String] = [:]
        for case let subscription as [String: Any] in (registered["subscriptions"] as? [Any]) ?? [] {
            if let id = subscription["stream_id"].flatMap(jsonInt), let name = subscription["name"] as? String {
                channelNames[id] = name
            }
        }
        // Reaction events from newer servers name the reactor only by id.
        var userNames: [Int: String] = [:]
        for case let user as [String: Any] in (registered["realm_users"] as? [Any]) ?? [] {
            if let id = user["user_id"].flatMap(jsonInt), let name = user["full_name"] as? String {
                userNames[id] = name
            }
        }
        if conversations != nil {
            await fetchOwnMessages(client, pipeline: pipeline, selfID: selfID)
        }
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
                switch event["type"] as? String {
                case "reaction":
                    if var reaction = ReactionEvent(event) {
                        if event["user"] == nil, let name = userNames[reaction.userID] {
                            reaction.userName = name
                        }
                        if let notification = pipeline.handleReaction(reaction, now: Date()) {
                            await sink.submit(notification)
                        }
                    }
                    continue
                case "realm_user":
                    if let person = event["person"] as? [String: Any], let id = person["user_id"].flatMap(jsonInt),
                       let name = person["full_name"] as? String {
                        userNames[id] = name  // a new user, or a renamed one
                    }
                    continue
                case "update_message":
                    if let conversations { follow(event, conversations, channelNames) }
                default:
                    break
                }
                if let notification = pipeline.handle(event) {
                    await sink.submit(notification)
                } else if event["type"] as? String != "message", let read = ReadEvent(event) {
                    await sink.handle(server: server, read)
                }
            }
        }
    }

    /// Your recent messages, so their topics are joined and reactions to them
    /// can be traced after a restart. A failure leaves them out.
    private func fetchOwnMessages(_ client: any ZulipAPI, pipeline: Pipeline, selfID: Int) async {
        guard let reply = try? await client.messages([
            "anchor": "newest", "num_before": 200, "num_after": 0, "apply_markdown": false,
            "narrow": [["operator": "sender", "operand": "me"]],
        ]), reply.succeeded else { return }
        for case let raw as [String: Any] in (reply["messages"] as? [Any]) ?? [] {
            let event: [String: Any] = ["message": raw, "flags": raw["flags"] as? [String] ?? []]
            guard let message = try? Message(server: server, host: client.credentials.host, selfID: selfID, event: event),
                  let timestamp = raw["timestamp"].flatMap(jsonInt)
            else { continue }
            pipeline.recordOwn(message, at: Date(timeIntervalSince1970: Double(timestamp)))
        }
    }

    /// Your messages moved to another topic or channel: their joined topic follows.
    private func follow(_ event: [String: Any], _ conversations: Conversations, _ channelNames: [Int: String]) {
        let newChannel = event["new_stream_id"].flatMap(jsonInt)
        let newTopic = event["subject"] as? String
        guard newChannel != nil || newTopic != nil else { return }  // an edit of the text
        let ids = (event["message_ids"] as? [Any])?.compactMap(jsonInt) ?? event["message_id"].flatMap(jsonInt).map { [$0] } ?? []
        for id in ids {
            guard let own = conversations.own(id), let old = own.place else { continue }
            let topic = newTopic ?? own.topic ?? old.topic
            let channelID = newChannel ?? old.channelID
            conversations.move(
                messageID: id, to: TopicKey(server: server, channelID: channelID, topic: topic),
                channelName: newChannel == nil ? own.channelName : channelNames[channelID], topic: topic
            )
        }
    }
}

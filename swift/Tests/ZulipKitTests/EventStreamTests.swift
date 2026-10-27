import Foundation
import Testing
import ZIrisCore
@testable import ZulipKit

/// test_stream.py's FakeClient: register always succeeds; events come from a
/// script of replies and errors, then empty replies.
final class FakeAPI: ZulipAPI, @unchecked Sendable {
    let credentials = try! Credentials(email: "me@x", key: "k", site: "https://chat.example.com/")
    private let lock = NSLock()
    private var script: [Result<[String: Any], Error>]
    private var unread: [[Int]?]
    private(set) var registered = 0
    private(set) var calls = 0
    var registerFailures = 0
    /// Your own messages, for GET /messages.
    var own: [[String: Any]] = []

    init(_ script: [Result<[String: Any], Error>], unread: [[Int]?] = []) {
        self.script = script
        self.unread = unread
    }

    func push(_ reply: [String: Any]) { lock.withLock { script.append(.success(reply)) } }

    func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject {
        try lock.withLock {
            registered += 1
            if registerFailures > 0 {
                registerFailures -= 1
                throw StreamError(description: "network down")
            }
            var reply: [String: Any] = [
                "result": "success", "queue_id": "q\(registered)", "last_event_id": -1,
                "subscriptions": [["stream_id": 7, "name": "python"], ["stream_id": 8, "name": "ops"]], "user_topics": [Any](),
            ]
            if !unread.isEmpty, let ids = unread.removeFirst() {
                reply["unread_msgs"] = ["pms": [Any](), "streams": [Any](), "huddles": [Any](), "mentions": ids]
            }
            return JSONObject(reply)
        }
    }

    func events(queueID: String, lastEventID: Int) async throws -> JSONObject {
        let step: Result<[String: Any], Error>? = lock.withLock {
            calls += 1
            return script.isEmpty ? nil : script.removeFirst()
        }
        guard let step else {
            try await Task.sleep(for: .milliseconds(5))
            return JSONObject(["result": "success", "events": [Any]()])
        }
        return JSONObject(try step.get())
    }

    func deregister(queueID: String) async throws -> JSONObject { JSONObject(["result": "success"]) }
    func profile() async throws -> JSONObject { JSONObject(["result": "success", "user_id": 5]) }
    func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject {
        JSONObject(["result": "success", "messages": lock.withLock { own }])
    }
    func streams() async throws -> JSONObject { JSONObject([:]) }

    var counts: (registered: Int, calls: Int) { lock.withLock { (registered, calls) } }
}

final class Sink: EventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var log: [String] { lock.withLock { seen } }

    func submit(_ notification: ZIrisCore.Notification) async {
        lock.withLock { seen.append("submit \(notification.message.id)") }
    }

    func handle(server: String, _ event: ReadEvent) async {
        lock.withLock { seen.append("\(server) \(event)") }
    }

    func reconcileUnread(server: String, unread: Set<Int>) async {
        lock.withLock { seen.append("reconcile \(server) \(unread.sorted())") }
    }
}

final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var last: String? { lock.withLock { all.last } }
    var list: [String] { lock.withLock { all } }
    func add(_ text: String) { lock.withLock { all.append(text) } }
}

private func dmEvent(_ id: Int) -> [String: Any] {
    [
        "id": id, "type": "message", "flags": [Any](),
        "message": [
            "id": 40 + id, "type": "private", "display_recipient": [["id": 9], ["id": 5]],
            "sender_id": 9, "sender_full_name": "Ada", "content": "yo",
        ] as [String: Any],
    ]
}

private func ok(_ events: [[String: Any]]) -> Result<[String: Any], Error> {
    .success(["result": "success", "events": events])
}

private var expired: Result<[String: Any], Error> { .success(["result": "error", "code": "BAD_EVENT_QUEUE_ID", "msg": "expired"]) }

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw StreamError(description: "timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private let config = try! parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n", sounds: ["chime": "/c.wav"])

private func start(_ api: FakeAPI, _ sink: Sink, _ statuses: Statuses = Statuses()) -> Task<Void, Never> {
    let stream = EventStream(
        server: "w", makeClient: { api }, sink: sink, config: { config },
        status: { statuses.add($0) }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }
    )
    return Task { await stream.run() }
}

@Suite struct EventStreamTests {
    @Test func eventsFlowAndQueueExpiryReregisters() async throws {
        let api = FakeAPI([ok([dmEvent(0)]), expired, ok([dmEvent(1)])])
        let sink = Sink()
        let task = start(api, sink)
        try await waitUntil { sink.log.count >= 2 }
        task.cancel()
        #expect(api.counts.registered == 2)
        #expect(sink.log == ["submit 40", "submit 41"])
    }

    @Test func aRegisterFailureIsReportedAndRetried() async throws {
        let api = FakeAPI([ok([dmEvent(0)])])
        api.registerFailures = 1
        let sink = Sink()
        let statuses = Statuses()
        let task = start(api, sink, statuses)
        try await waitUntil { sink.log.count >= 1 }
        task.cancel()
        #expect(api.counts.registered == 2)
        #expect(statuses.list.contains("error: network down"))
    }

    @Test func aNetworkDropKeepsTheQueueSoMissedEventsStillArrive() async throws {
        let api = FakeAPI([ok([dmEvent(0)]), .failure(StreamError(description: "network down")), ok([dmEvent(1)])])
        let sink = Sink()
        let statuses = Statuses()
        let task = start(api, sink, statuses)
        try await waitUntil { sink.log.count >= 2 }
        task.cancel()
        #expect(api.counts.registered == 1)
        #expect(sink.log == ["submit 40", "submit 41"])
        #expect(statuses.list.contains("reconnecting: network down"))
        #expect(statuses.last == "connected")
    }

    @Test func readEventsReachTheSink() async throws {
        #expect(Set(["update_message_flags", "delete_message"]).isSubset(of: eventTypes))
        let read: [String: Any] = ["id": 2, "type": "update_message_flags", "op": "add", "flag": "read", "messages": [40]]
        let other: [String: Any] = ["id": 3, "type": "heartbeat"]
        let api = FakeAPI([ok([dmEvent(0), read, other])])
        let sink = Sink()
        let task = start(api, sink)
        try await waitUntil { sink.log.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        #expect(sink.log == ["submit 40", "w read(Optional(Set([40])))"])
    }

    @Test func eachRegisterReconcilesUnread() async throws {
        let api = FakeAPI([expired, expired], unread: [[1, 2], nil, [3]])
        let sink = Sink()
        let task = start(api, sink)
        try await waitUntil { api.counts.registered >= 3 && sink.log.count >= 2 }
        task.cancel()
        #expect(sink.log == ["reconcile w [1, 2]", "reconcile w [3]"])
    }

    @Test func registerFailureMessageIsTheServers() async throws {
        final class Refusing: ZulipAPI, @unchecked Sendable {
            let credentials = try! Credentials(email: "me@x", key: "k", site: "chat.example.com")
            func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject {
                JSONObject(["result": "error", "msg": "Your account has been deactivated"])
            }
            func events(queueID: String, lastEventID: Int) async throws -> JSONObject { JSONObject([:]) }
            func deregister(queueID: String) async throws -> JSONObject { JSONObject([:]) }
            func profile() async throws -> JSONObject { JSONObject([:]) }
            func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject { JSONObject([:]) }
            func streams() async throws -> JSONObject { JSONObject([:]) }
        }
        let statuses = Statuses()
        let stream = EventStream(server: "w", makeClient: { Refusing() }, sink: Sink(), config: { config },
                                 status: { statuses.add($0) }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        let task = Task { await stream.run() }
        try await waitUntil { statuses.list.count >= 2 }
        task.cancel()
        #expect(statuses.list.prefix(2) == ["connecting", "error: Your account has been deactivated"])
    }

    @Test func unreadIDsFromRegister() {
        let registered: [String: Any] = ["unread_msgs": [
            "pms": [["other_user_id": 9, "unread_message_ids": [1, 2]]],
            "streams": [["stream_id": 7, "topic": "t", "unread_message_ids": [3]]],
            "huddles": [["user_ids_string": "5,9,12", "unread_message_ids": [4]]],
            "mentions": [5, 3], "count": 5,
        ] as [String: Any]]
        #expect(unreadIDs(registered) == [1, 2, 3, 4, 5])
        let newer: [String: Any] = ["unread_msgs": ["direct_message": [["unread_message_ids": [8]]],
                                                    "streams": [Any](), "huddles": [Any](), "mentions": [Any]()] as [String: Any]]
        #expect(unreadIDs(newer) == [8])
        #expect(unreadIDs([:]) == nil)
        var missing = registered["unread_msgs"] as! [String: Any]
        missing["old_unreads_missing"] = true
        #expect(unreadIDs(["unread_msgs": missing]) == nil)
    }
}

private let quiet = try! parseConfig(
    "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n[defaults]\nnotify_channel_messages = false\n", sounds: ["chime": "/c.wav"]
)

private func channelEvent(_ id: Int, eventID: Int, topic: String) -> [String: Any] {
    ["id": eventID, "type": "message", "flags": [Any](), "message": [
        "id": id, "type": "stream", "stream_id": 7, "display_recipient": "python", "subject": topic,
        "sender_id": 9, "sender_full_name": "Ada", "content": "hi",
    ] as [String: Any]]
}

private func ownMessage(_ id: Int, topic: String, hoursAgo: Double = 1) -> [String: Any] {
    ["id": id, "type": "stream", "stream_id": 7, "display_recipient": "python", "subject": topic,
     "sender_id": 5, "sender_full_name": "Me", "content": "mine", "flags": ["read"],
     "timestamp": Int(Date().timeIntervalSince1970 - hoursAgo * 3600)]
}

private func startJoined(_ api: FakeAPI, _ sink: Sink, _ store: Conversations) -> Task<Void, Never> {
    let stream = EventStream(
        server: "w", makeClient: { api }, sink: sink, config: { quiet }, status: { _ in },
        sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }, conversations: store
    )
    return Task { await stream.run() }
}

@Suite struct ConversationStreamTests {
    @Test func ownMessagesAreFetchedAndJoined() async throws {
        let api = FakeAPI([ok([channelEvent(1, eventID: 0, topic: "c"), channelEvent(2, eventID: 1, topic: "A")])])
        api.own = [ownMessage(100, topic: "a"), ownMessage(101, topic: "b"), ownMessage(102, topic: "old", hoursAgo: 100)]
        let store = Conversations(file: nil, hours: { 48 })
        let sink = Sink()
        let task = startJoined(api, sink, store)
        try await waitUntil { api.counts.calls >= 2 }
        task.cancel()
        #expect(sink.log == ["submit 2"])
        #expect(store.isJoined(TopicKey(server: "w", channelID: 7, topic: "b")))
        #expect(!store.isJoined(TopicKey(server: "w", channelID: 7, topic: "old")))
        #expect(store.own(102)?.topic == "old")  // still yours, for reactions
    }

    @Test func reactionEventsReachTheSink() async throws {
        let api = FakeAPI([ok([[
            "id": 0, "type": "reaction", "op": "add", "message_id": 100, "user_id": 9,
            "user": ["user_id": 9, "full_name": "Ada"], "emoji_name": "tada", "emoji_code": "1f389",
            "reaction_type": "unicode_emoji",
        ]])])
        api.own = [ownMessage(100, topic: "a")]
        let sink = Sink()
        let task = startJoined(api, sink, Conversations(file: nil, hours: { 48 }))
        try await waitUntil { sink.log.count >= 1 }
        task.cancel()
        #expect(sink.log == ["submit 100"])
    }

    @Test func movesFollowTheTopic() async throws {
        let api = FakeAPI([ok([
            ["id": 0, "type": "update_message", "message_id": 100, "message_ids": [100], "stream_id": 7,
             "orig_subject": "a", "subject": "renamed", "propagate_mode": "change_all"],
            channelEvent(1, eventID: 1, topic: "renamed"),
            ["id": 2, "type": "update_message", "message_id": 100, "message_ids": [100], "stream_id": 7,
             "new_stream_id": 8, "propagate_mode": "change_all"],
        ])])
        api.own = [ownMessage(100, topic: "a")]
        let store = Conversations(file: nil, hours: { 48 })
        let sink = Sink()
        let task = startJoined(api, sink, store)
        try await waitUntil { api.counts.calls >= 2 }
        task.cancel()
        #expect(sink.log == ["submit 1"])
        #expect(!store.isJoined(TopicKey(server: "w", channelID: 7, topic: "a")))
        #expect(store.isJoined(TopicKey(server: "w", channelID: 8, topic: "renamed")))
        #expect(store.own(100)?.topic == "renamed" && store.own(100)?.channelName == "ops")
    }
}

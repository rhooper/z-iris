import Foundation
import Testing
import ZIrisCore
@testable import ZulipKit

/// A server for the editor's fetches: streams and messages from closures.
final class EditorAPI: ZulipAPI, @unchecked Sendable {
    let credentials = try! Credentials(email: "me@x", key: "k", site: "https://chat.example.com/")
    private let lock = NSLock()
    private var recorded: [[String: any Sendable]] = []
    private let traffic: [String: Int?]
    private let pages: @Sendable ([String: any Sendable]) -> [String: Any]

    init(traffic: [String: Int?] = [:], pages: @escaping @Sendable ([String: any Sendable]) -> [String: Any] = { _ in [:] }) {
        self.traffic = traffic
        self.pages = pages
    }

    var requests: [[String: any Sendable]] { lock.withLock { recorded } }

    func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject {
        JSONObject(["result": "success", "queue_id": "q", "last_event_id": 1,
                    "subscriptions": [["stream_id": 7, "name": "ops", "is_muted": false]],
                    "user_topics": [["stream_id": 7, "topic_name": "noise", "visibility_policy": 1]]])
    }
    func events(queueID: String, lastEventID: Int) async throws -> JSONObject { JSONObject([:]) }
    func deregister(queueID: String) async throws -> JSONObject { JSONObject(["result": "success"]) }
    func profile() async throws -> JSONObject { JSONObject(["result": "success", "user_id": 5]) }
    func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject {
        lock.withLock { recorded.append(parameters) }
        return JSONObject(["result": "success"].merging(pages(parameters)) { $1 })
    }
    func streams() async throws -> JSONObject {
        JSONObject(["result": "success", "streams": traffic.enumerated().map { index, entry in
            ["name": entry.key, "stream_id": index, "stream_weekly_traffic": entry.value as Any? ?? NSNull()] as [String: Any]
        }])
    }
}

private func streamMessage(_ id: Int, channel: String = "ops", flags: [String] = []) -> [String: Any] {
    ["id": id, "type": "stream", "stream_id": 7, "display_recipient": channel, "subject": "t",
     "sender_id": 9, "sender_full_name": "Ada", "content": "hi", "flags": flags]
}

private let draft = try! parseConfig("""
[[server]]
name = "work"
zuliprc = "/x/zuliprc"
[[rule]]
name = "ops"
match = "channel"
channel = "ops"
volume = 80
sound = "chime"
""", sounds: ["chime": "/c.wav"])

private func isMentions(_ request: [String: any Sendable]) -> Bool { request["narrow"] != nil }
private func anchor(_ request: [String: any Sendable]) -> String { "\(request["anchor"]!)" }

@Suite struct ChannelSourceTests {
    private func server(_ name: String) -> ServerConfig { ServerConfig(name: name, zuliprc: "/" + name) }

    @Test func busiestFirstPerServerAndAll() async {
        let apis = ["a": EditorAPI(traffic: ["quiet": 1, "Busy": 500, "new": nil, "mid": 40]),
                    "b": EditorAPI(traffic: ["quiet": 900, "other": 3])]
        let source = ChannelSource(client: { apis[$0.name]! })
        let result = await source.channels([server("a"), server("b")])
        #expect(result.servers.map(\.channels) == [["Busy", "mid", "quiet", "new"], ["quiet", "other"]])
        // Across servers a channel counts its busiest server.
        #expect(result.all == ["quiet", "Busy", "mid", "other", "new"])
        #expect(busiest(["b": 5, "A": 5, "c": 5]) == ["A", "b", "c"])
    }

    @Test func cachedAndErrorsReportedPerServer() async {
        let calls = Counter()
        let source = ChannelSource(client: { _ in calls.increment(); return EditorAPI(traffic: ["x": 1]) }, now: { 0 })
        _ = await source.channels([server("a")])
        _ = await source.channels([server("a")])
        #expect(calls.increment() == 2)
        let broken = ChannelSource(client: { _ in throw ZulipClientError(description: "offline") })
        let result = await broken.channels([server("a")])
        #expect(result.servers[0].error?.contains("offline") == true && result.all.isEmpty)
    }
}

@Suite struct PreviewSourceTests {
    @Test func reportsTheRuleAndWhy() async {
        let api = EditorAPI(pages: { isMentions($0) ? ["messages": [Any]()] : ["messages": [streamMessage(1), streamMessage(2, channel: "dev")]] })
        let result = await PreviewSource(client: { _ in api }).preview(draft)
        let entries = result[0].messages
        #expect(entries.map(\.id) == [2, 1])
        #expect(entries[1].why == "rule" && entries[1].sound == "c" && entries[1].volume == 80)  // the file's stem, as Path(...).stem
        #expect(entries[0].why == "channel messages not enabled" && !entries[0].notify)
    }

    @Test func cachedUntilItExpiresOrARefresh() async {
        let made = Counter()
        let clock = Clock()
        let source = PreviewSource(client: { _ in made.increment(); return EditorAPI(pages: { _ in ["messages": [Any]()] }) },
                                   now: { clock.now }, ttl: 60)
        _ = await source.preview(draft)
        _ = await source.preview(draft)
        clock.advance(61)
        _ = await source.preview(draft)
        _ = await source.preview(draft, refresh: true)
        #expect(made.increment() == 4)
    }

    @Test func aFailingServerIsAnErrorAndAMalformedMessageIsSkipped() async {
        let failing = await PreviewSource(client: { _ in throw ZulipClientError(description: "boom") }).preview(draft)
        #expect(failing[0].error?.contains("boom") == true && failing[0].messages.isEmpty)
        let api = EditorAPI(pages: { _ in ["messages": [streamMessage(1), ["id": 2]]] })
        let result = await PreviewSource(client: { _ in api }).preview(draft)
        #expect(result[0].messages.map(\.id) == [1])
    }

    @Test func olderMentionsAreIncludedOnce() async {
        let api = EditorAPI(pages: {
            isMentions($0) ? ["messages": [streamMessage(2, flags: ["mentioned"]), streamMessage(11, flags: ["mentioned"])]]
                : ["messages": [streamMessage(10), streamMessage(11, flags: ["mentioned"])]]
        })
        let result = await PreviewSource(client: { _ in api }).preview(draft)
        #expect(result[0].messages.map(\.id) == [11, 10, 2])
    }

    @Test func morePagesBackFromTheWindowAndStopsAtTheOldest() async {
        let api = EditorAPI(pages: { request in
            if isMentions(request) { return ["messages": [streamMessage(2, flags: ["mentioned"])]] }
            if anchor(request) == "newest" { return ["messages": [streamMessage(10), streamMessage(11)], "found_oldest": false] }
            return ["messages": [streamMessage(8), streamMessage(9)], "found_oldest": true]
        })
        let source = PreviewSource(client: { _ in api })
        let first = await source.preview(draft)
        #expect((first[0].fetched, first[0].complete) == (3, false))
        let more = await source.preview(draft, more: true)
        #expect(more[0].messages.map(\.id) == [11, 10, 9, 8, 2])
        #expect((more[0].fetched, more[0].complete) == (5, true))
        let again = await source.preview(draft, more: true)
        #expect(again[0].fetched == 5)
        let older = api.requests.filter { !isMentions($0) && anchor($0) != "newest" }
        #expect(older.count == 1 && anchor(older[0]) == "10" && older[0]["include_anchor"] as? Bool == false)
    }

    @Test func aFailedPageKeepsWhatWasFetched() async {
        let fail = Flag()
        let source = PreviewSource(client: { _ in
            if fail.isSet { throw ZulipClientError(description: "offline") }
            return EditorAPI(pages: { _ in ["messages": [streamMessage(1)], "found_oldest": false] })
        })
        _ = await source.preview(draft)
        fail.set()
        let result = await source.preview(draft, more: true)
        #expect(result[0].fetched == 1 && result[0].error?.contains("offline") == true)
        #expect(result[0].messages.map(\.id) == [1])
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

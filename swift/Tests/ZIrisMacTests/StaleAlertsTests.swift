import Foundation
import Testing
import ZIrisCore
@testable import ZulipKit
@testable import ZIrisMac

/// A server that answers message lookups: read, unread, gone, or offline.
private final class Messages: ZulipAPI, @unchecked Sendable {
    let credentials = try! Credentials(email: "me@x", key: "k", site: "https://chat.example.com/")
    let read: Set<Int>, gone: Set<Int>, offline: Bool
    private let lock = NSLock()
    private var _asked: [Int] = []
    var asked: [Int] { lock.withLock { _asked } }

    init(read: Set<Int> = [], gone: Set<Int> = [], offline: Bool = false) {
        self.read = read
        self.gone = gone
        self.offline = offline
    }

    func message(_ id: Int) async throws -> JSONObject {
        lock.withLock { _asked.append(id) }
        if offline { throw ZulipClientError(description: "offline") }
        if gone.contains(id) { return JSONObject(["result": "error", "msg": "Invalid message(s)", "code": "BAD_REQUEST"]) }
        return JSONObject(["result": "success", "message": ["id": id, "flags": read.contains(id) ? ["read"] : []]])
    }
    func register(eventTypes: [String], applyMarkdown: Bool, clientGravatar: Bool) async throws -> JSONObject { JSONObject([:]) }
    func events(queueID: String, lastEventID: Int) async throws -> JSONObject { JSONObject([:]) }
    func deregister(queueID: String) async throws -> JSONObject { JSONObject([:]) }
    func profile() async throws -> JSONObject { JSONObject([:]) }
    func messages(_ parameters: [String: any Sendable]) async throws -> JSONObject { JSONObject([:]) }
    func streams() async throws -> JSONObject { JSONObject([:]) }
    func users() async throws -> JSONObject { JSONObject([:]) }
}

private final class Cleared: @unchecked Sendable {
    private let lock = NSLock()
    private var _groups: [String] = []
    var groups: [String] { lock.withLock { _groups } }
    func add(_ groups: [String]) { lock.withLock { _groups += groups } }
}

@Suite struct StaleAlertsTests {
    @Test func clearsAlertsForReadOrDeletedMessages() async {
        let work = Messages(read: [5], gone: [6])
        let cleared = Cleared()
        let sweep = StaleAlerts(
            servers: { ["w", "w-x"] }, client: { $0 == "w" ? work : nil },
            delivered: { ["z-iris-w-5", "z-iris-w-6", "z-iris-w-7", "z-iris-conversation-w-22-a76e41114ff4", "z-iris-w-x-8", "z-iris"] },
            clear: { cleared.add($0) })
        #expect(await sweep.sweep() == ["z-iris-w-5", "z-iris-w-6"])
        #expect(cleared.groups == ["z-iris-w-5", "z-iris-w-6"])
        // Summaries and other names are not looked up; w-x has no client yet.
        #expect(work.asked == [5, 6, 7])
    }

    @Test func nothingClearedWhenTheServerOrTheHelperDoesNotAnswer() async {
        let cleared = Cleared()
        let offline = StaleAlerts(servers: { ["w"] }, client: { _ in Messages(offline: true) },
                                  delivered: { ["z-iris-w-5"] }, clear: { cleared.add($0) })
        #expect(await offline.sweep().isEmpty)
        let silent = StaleAlerts(servers: { ["w"] }, client: { _ in Messages(read: [5]) },
                                 delivered: { nil }, clear: { cleared.add($0) })
        #expect(await silent.sweep().isEmpty)
        #expect(cleared.groups.isEmpty)
    }

    @Test func messageAlertsByServer() {
        #expect(messageAlert("z-iris-w-x-8", servers: ["w", "w-x"])! == ("w-x", 8))
        #expect(messageAlert("z-iris-w-12", servers: ["w", "w-x"])! == ("w", 12))
        #expect(messageAlert("z-iris-w-", servers: ["w"]) == nil)
        #expect(messageAlert("z-iris-v-3", servers: ["w"]) == nil)
    }
}

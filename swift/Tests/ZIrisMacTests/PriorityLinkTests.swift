import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

private var okStatus: [String: Any] { ["ok": true, "allowed": true, "style": "alert"] }
private let body = "-x \"q\"\nline2 🎉"

/// test_prioritylink.py's FakeChild: script maps an op to a reply, "hang"
/// (never answers) or "die" (exits without answering).
final class FakeChild: PriorityChild {
    private var script: [String: Any]
    private(set) var requests: [[String: Any]] = []
    private(set) var alive = true
    private(set) var hung = false
    private(set) var killed = false

    init(_ script: [String: Any] = [:]) {
        self.script = ["status": okStatus, "show": ["ok": true], "clear": ["ok": true], "clear_server": ["ok": true]]
            .merging(script) { $1 }
    }

    func ask(_ request: [String: Any], timeout: Double) -> [String: Any]? {
        guard alive else { return nil }
        // What goes down the pipe: one JSON line, read back as the child would.
        let line = try! JSONSerialization.data(withJSONObject: request)
        #expect(!line.contains(0x0A))
        let decoded = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
        requests.append(decoded)
        switch script[decoded["op"] as! String] {
        case let reply as [String: Any]:
            return reply
        case "die" as String:
            alive = false
            return nil
        default:  // hang: the link's timeout kills it
            hung = true
            killed = true
            alive = false
            return nil
        }
    }
}

final class FakeFallback: Notifying, @unchecked Sendable {
    private(set) var shown: [(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?)] = []
    private(set) var threads: [String?] = []
    private(set) var cleared: [String] = []

    func show(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?,
              thread: String?) async {
        shown.append((title, body, url, image, group, sender))
        threads.append(thread)
    }

    func clear(_ group: String) async { cleared.append(group) }
}

private func makeApp() throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-\(UUID().uuidString)/z-iris-priority.app")
    let executable = priorityExecutable(app)
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: executable)
    return app
}

private final class Harness {
    let fallback = FakeFallback()
    var warnings: [String] = []
    var started = 0
    var children: [FakeChild]
    var link: PriorityLink!

    init(_ children: [FakeChild], app: URL? = nil) throws {
        self.children = children
        let app = try app ?? makeApp()
        link = PriorityLink(fallback: fallback, app: app, start: { [unowned self] _ in
            self.started += 1
            return self.children.removeFirst()
        }, warn: { [unowned self] in self.warnings.append($0) }, timeout: 1)
    }
}

private let ada = Sender(handle: "zulip:w:9", name: "Ada \"x\"\n🎉", avatar: "/c/av.png", picture: nil, conversation: "w:dm:9")

@Suite struct PriorityLinkTests {
    @Test func showSendsOneRequestAndTheSameChildServesLaterOnes() async throws {
        let child = FakeChild()
        let h = try Harness([child])
        await h.link.show(title: "Ada", body: body, url: "zulip://h/#narrow/dm/9", image: "/a.png", group: "z-iris-work-7", sender: nil)
        let shows = child.requests.filter { $0["op"] as? String == "show" }
        #expect(shows.count == 1)
        #expect(NSDictionary(dictionary: shows[0]) == NSDictionary(dictionary: [
            "op": "show", "title": "Ada", "body": body, "url": "zulip://h/#narrow/dm/9", "group": "z-iris-work-7", "image": "/a.png",
        ]))
        #expect(h.fallback.shown.isEmpty && h.started == 1)
        await h.link.show(title: "Bob", body: "x", url: "u", image: nil, group: "z-iris-work-8", sender: nil)
        #expect(h.started == 1)
        #expect(child.requests.last?["image"] is NSNull)
    }

    @Test func aRefusalFallsBackToABanner() async throws {
        let h = try Harness([FakeChild(["show": ["ok": false, "reason": "not allowed"]])])
        await h.link.show(title: "Ada", body: body, url: "u", image: nil, group: "z-iris-work-7", sender: nil)
        #expect(h.fallback.shown.map(\.title) == ["Ada"] && h.fallback.shown[0].group == "z-iris-work-7")
        #expect(h.warnings.contains { $0.contains("not allowed") })
    }

    @Test func aHungChildFallsBackWithoutARestart() async throws {
        let child = FakeChild(["show": "hang"])
        let h = try Harness([child, FakeChild()])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g", sender: nil)
        #expect(h.fallback.shown.count == 1 && child.killed && h.started == 1)
    }

    @Test func aDeadChildIsRestartedOnce() async throws {
        let second = FakeChild()
        let h = try Harness([FakeChild(["show": "die"]), second])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g", sender: nil)
        #expect(h.started == 2 && h.fallback.shown.isEmpty)
        #expect(second.requests.map { $0["op"] as! String } == ["status", "show"])
    }

    @Test func aChildThatDiesTwiceFallsBack() async throws {
        let h = try Harness([FakeChild(["show": "die"]), FakeChild(["show": "die"])])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g", sender: nil)
        #expect(h.started == 2 && h.fallback.shown.count == 1)
    }

    @Test func aMissingAppFallsBackWithoutStartingAndWarnsOnce() async throws {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("nowhere-\(UUID().uuidString)/z-iris-priority.app")
        let h = try Harness([], app: nowhere)
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g1", sender: nil)
        await h.link.show(title: "Ada", body: "y", url: "u", image: nil, group: "g2", sender: nil)
        #expect(h.started == 0 && h.fallback.shown.count == 2 && h.warnings.count == 1)
        h.link.clearGroups(["g"])
        h.link.clearServer("w", keep: [])
        #expect(h.warnings.count == 1)  // clears without the app are quiet
    }

    @Test func theStyleWarningComesOnce() async throws {
        let h = try Harness([FakeChild(["status": ["ok": true, "allowed": true, "style": "banner"]])])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g1", sender: nil)
        await h.link.show(title: "Ada", body: "y", url: "u", image: nil, group: "g2", sender: nil)
        let style = h.warnings.filter { $0.contains("set to banner") }
        #expect(style.count == 1)
        #expect(style[0].contains("set Alerts in System Settings, Notifications, z-iris priority"))
    }

    @Test func clearsSendTheirRequests() async throws {
        let child = FakeChild()
        let h = try Harness([child])
        await h.link.clear("z-iris-w-1")
        h.link.clearServer("w", keep: [5, 2])
        h.link.clearGroups(["z-iris-w-1", "z-iris-w-2"])
        let sent = child.requests.dropFirst().map { NSDictionary(dictionary: $0) }
        #expect(sent == [
            NSDictionary(dictionary: ["op": "clear", "groups": ["z-iris-w-1"]]),
            NSDictionary(dictionary: ["op": "clear_server", "server": "w", "keep": [2, 5]]),
            NSDictionary(dictionary: ["op": "clear", "groups": ["z-iris-w-1", "z-iris-w-2"]]),
        ])
        #expect(h.fallback.shown.isEmpty)
    }

    @Test func failedClearsWarnOnceAndShowNothing() async throws {
        let h = try Harness([FakeChild(["clear": ["ok": false, "reason": "boom"]])])
        for _ in 0..<3 { await h.link.clear("z-iris-w-1") }
        #expect(h.warnings.filter { $0.contains("could not clear") }.count == 1)
        #expect(h.fallback.shown.isEmpty)
    }

    @Test func theSenderTravelsIntactAndSurvivesTheFallback() async throws {
        let child = FakeChild()
        let h = try Harness([child])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g", sender: ada)
        let sent = child.requests.first { $0["op"] as? String == "show" }!
        #expect(Sender(json: sent["sender"]!) == ada)

        let refused = try Harness([FakeChild(["show": ["ok": false, "reason": "not allowed"]])])
        await refused.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g", sender: ada)
        #expect(refused.fallback.shown.first?.sender == ada)
    }

    @Test func plainRepliesWarnOnce() async throws {
        let h = try Harness([FakeChild(["show": ["ok": true, "plain": "no entitlement"]])])
        await h.link.show(title: "Ada", body: "x", url: "u", image: nil, group: "g1", sender: ada)
        await h.link.show(title: "Ada", body: "y", url: "u", image: nil, group: "g2", sender: ada)
        #expect(h.fallback.shown.isEmpty)
        #expect(h.warnings.filter { $0.contains("no entitlement") }.count == 1)
    }

    @Test func theRealPipeCarriesOneLineEachWay() throws {
        let echo = try ProcessChild(URL(fileURLWithPath: "/bin/cat"))
        let reply = echo.ask(["op": "show", "body": body], timeout: 2)
        #expect(reply?["body"] as? String == body)
        #expect(echo.ask(["op": "status"], timeout: 2)?["op"] as? String == "status")
        echo.kill()
    }

    @Test func aSilentRealChildIsKilledAsHung() throws {
        let silent = try ProcessChild(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        #expect(silent.ask(["op": "status"], timeout: 0.2) == nil)
        #expect(silent.hung)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!silent.alive)
    }
}

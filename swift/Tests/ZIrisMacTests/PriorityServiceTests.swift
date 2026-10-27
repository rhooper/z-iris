import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

/// A notification center in memory.
final class FakeAlerts: AlertCenter, @unchecked Sendable {
    struct Sent { var identifier, title, body: String; var attachment: String? }

    private let lock = NSLock()
    private var status: String
    private let style: String
    private var _sent: [Sent] = []
    private var _delivered: [String]
    private var _cleared: [String] = []
    private var _prompted = 0
    private let promptNeverAnswers: Bool

    init(status: String = "allowed", style: String = "alert", delivered: [String] = [], promptNeverAnswers: Bool = false) {
        self.status = status
        self.style = style
        _delivered = delivered
        self.promptNeverAnswers = promptNeverAnswers
    }

    var sent: [Sent] { lock.withLock { _sent } }
    var cleared: [String] { lock.withLock { _cleared } }
    var delivered: [String] { lock.withLock { _delivered } }
    var prompted: Int { lock.withLock { _prompted } }

    func authorization() async -> String { lock.withLock { status } }
    func alertStyle() async -> String { style }
    func requestAuthorization() async {
        lock.withLock { _prompted += 1 }
        if promptNeverAnswers { try? await Task.sleep(for: .seconds(3600)) }
    }
    func add(identifier: String, title: String, body: String, attachment: String?, thread: String?) async throws {
        lock.withLock {
            _sent.append(Sent(identifier: identifier, title: title, body: body, attachment: attachment))
            _delivered.append(identifier)
        }
    }
    func delivered() async -> [String] { delivered }
    func remove(_ identifiers: [String]) async {
        lock.withLock {
            _cleared += identifiers
            _delivered.removeAll(where: identifiers.contains)
        }
    }
}

final class Comms: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(String, Sender)] = []
    let fail: String?
    init(fail: String? = nil) { self.fail = fail }
    var sent: [(String, Sender)] { lock.withLock { _sent } }

    var send: SendCommunication {
        { [self] id, _, _, sender, _ in
            if let fail { throw CommsError(description: fail) }
            lock.withLock { _sent.append((id, sender)) }
        }
    }
}

private var show: [String: Any] {
    ["op": "show", "title": "Ada", "body": "-x \"q\"\nline2 🎉", "url": "zulip://h/#narrow/dm/9", "group": "z-iris-work-7"]
}
private let sender = Sender(handle: "zulip:w:9", name: "Ada", avatar: "/c/av.png", picture: nil, conversation: "w:dm:9")

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-priority-\(UUID().uuidString)")
}

private func service(_ dir: URL, _ alerts: FakeAlerts = FakeAlerts(), opened: Lines = Lines(),
                     comms: Comms = Comms(), entitled: Bool = false) -> PriorityService {
    PriorityService(center: alerts, urls: URLStore(url: dir.appendingPathComponent("urls.json")),
                    opener: { opened.add($0) }, comms: comms.send, entitled: entitled, pictures: dir)
}

@Suite struct PriorityServiceTests {
    @Test func statusReportsPermissionAndStyleWithoutPrompting() async {
        let reply = await service(folder(), FakeAlerts(style: "banner")).handle(["op": "status"])
        #expect(NSDictionary(dictionary: reply) == ["ok": true, "allowed": true, "style": "banner"])
        let undecided = FakeAlerts(status: "undetermined", promptNeverAnswers: true)
        let status = await service(folder(), undecided).handle(["op": "status"])
        #expect(status["allowed"] as? Bool == false && undecided.prompted == 0)
    }

    @Test func showSendsAnAlertWithTheGroupAsIdentifierAndKeepsTheURL() async {
        let dir = folder()
        let alerts = FakeAlerts()
        #expect(NSDictionary(dictionary: await service(dir, alerts).handle(show)) == ["ok": true])
        #expect(alerts.sent.map(\.identifier) == ["z-iris-work-7"])
        #expect((alerts.sent[0].title, alerts.sent[0].body) == ("Ada", show["body"] as! String))
        #expect(URLStore(url: dir.appendingPathComponent("urls.json")).pop("z-iris-work-7") == "zulip://h/#narrow/dm/9")
    }

    @Test func anExistingImageIsAttached() async throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("a.png")
        try Data("x".utf8).write(to: image)
        let alerts = FakeAlerts()
        var request = show
        request["image"] = image.path
        _ = await service(dir, alerts).handle(request)
        request["image"] = dir.appendingPathComponent("gone.png").path
        _ = await service(dir, alerts).handle(request)
        #expect(alerts.sent.map(\.attachment) == [image.path, nil])
    }

    @Test func notAllowedOrUndecided() async {
        let denied = FakeAlerts(status: "denied")
        #expect(NSDictionary(dictionary: await service(folder(), denied).handle(show)) == ["ok": false, "reason": "not allowed"])
        #expect(denied.sent.isEmpty)
        let undecided = FakeAlerts(status: "undetermined", promptNeverAnswers: true)
        let svc = service(folder(), undecided)
        let first = await svc.handle(show), second = await svc.handle(show)
        #expect(first["reason"] as? String == "waiting for permission" && second["reason"] as? String == "waiting for permission")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(undecided.prompted == 1 && undecided.sent.isEmpty)
        _ = await svc.handle(["op": "clear", "groups": ["z-iris-w-1"]])
        _ = await svc.handle(["op": "clear_server", "server": "w", "keep": [Int]()])
        #expect(undecided.prompted == 1)  // clears never prompt
    }

    @Test func aClickOpensTheURLOnceEvenAfterARestart() async {
        let dir = folder()
        let opened = Lines()
        let svc = service(dir, opened: opened)
        _ = await svc.handle(show)
        svc.clicked("z-iris-work-7")
        svc.clicked("z-iris-work-7")
        #expect(opened.all == ["zulip://h/#narrow/dm/9"])
        _ = await svc.handle(show)
        let restarted = Lines()
        service(dir, opened: restarted).clicked("z-iris-work-7")
        #expect(restarted.all == ["zulip://h/#narrow/dm/9"])
    }

    @Test func clearsRemoveOnlyWhatIsOnScreenAndTheirURLs() async {
        let alerts = FakeAlerts(delivered: ["z-iris-w-3"])
        let opened = Lines()
        let svc = service(folder(), alerts, opened: opened)
        _ = await svc.handle(show)
        let groups = (1...5000).map { "z-iris-w-\($0)" } + ["z-iris-work-7"]
        #expect(NSDictionary(dictionary: await svc.handle(["op": "clear", "groups": groups])) == ["ok": true])
        #expect(alerts.cleared == ["z-iris-w-3", "z-iris-work-7"])
        svc.clicked("z-iris-work-7")
        #expect(opened.all.isEmpty)
    }

    @Test func clearServerKeepsUnreadAndOtherServers() async {
        let alerts = FakeAlerts(delivered: ["z-iris-w-1", "z-iris-w-2", "z-iris-w-2-5", "z-iris-a.b-3", "z-iris-axb-4", "other"])
        let svc = service(folder(), alerts)
        #expect(NSDictionary(dictionary: await svc.handle(["op": "clear_server", "server": "w", "keep": [2]])) == ["ok": true])
        #expect(alerts.cleared == ["z-iris-w-1"])
        _ = await svc.handle(["op": "clear_server", "server": "a.b", "keep": [Int]()])
        #expect(alerts.cleared == ["z-iris-w-1", "z-iris-a.b-3"])
    }

    @Test func clearServerClearsSummariesNotKept() async {
        let summaries = ["z-iris-conversation-w-7-8efd86fb78a5", "z-iris-conversation-w-8-0123456789ab", "z-iris-conversation-wx-1-0123456789ab"]
        let alerts = FakeAlerts(delivered: summaries)
        let svc = service(folder(), alerts)
        _ = await svc.handle(["op": "clear_server", "server": "w", "keep": [Int](), "keep_groups": [summaries[1]]])
        #expect(alerts.cleared == [summaries[0]])  // after a restart nothing is kept: no summary outlives its topic
        _ = await svc.handle(["op": "clear_server", "server": "w", "keep": [Int]()])
        #expect(alerts.cleared == [summaries[0], summaries[1]])
    }

    @Test func clearServerLeavesSummariesOfServersSharingItsPrefix() async {
        let other = "z-iris-conversation-w-x-7-8efd86fb78a5"  // server "w-x"
        let alerts = FakeAlerts(delivered: [other, "z-iris-conversation-w-7-8efd86fb78a5"])
        let svc = service(folder(), alerts)
        _ = await svc.handle(["op": "clear_server", "server": "w", "keep": [Int]()])
        #expect(alerts.cleared == ["z-iris-conversation-w-7-8efd86fb78a5"])
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6])
    func malformedRequestsReplyNotOK(_ index: Int) async {
        let requests: [Any] = [[String: Any](), ["op": "show"], ["op": "nope"], ["op": "clear", "groups": "z-iris-w-1"],
                               ["op": "clear_server", "server": "w", "keep": ["x"]], [Any](), "show"]
        let reply = await service(folder()).handle(requests[index])
        #expect(reply["ok"] as? Bool == false && !((reply["reason"] as? String) ?? "").isEmpty)
    }

    @Test func eachLineGetsOneReply() async {
        let svc = service(folder())
        let status = await priorityReply(#"{"op":"status"}"#, svc)
        let garbage = await priorityReply("garbage", svc)
        #expect(!status.contains("\n") && !garbage.contains("\n"))
        #expect(NSDictionary(dictionary: try! JSONSerialization.jsonObject(with: Data(garbage.utf8)) as! [String: Any])
            == ["ok": false, "reason": "bad json"])
    }

    @Test func aSenderIsACommunicationAlert() async {
        let dir = folder()
        let comms = Comms(), alerts = FakeAlerts()
        var request = show
        request["sender"] = sender.toJSON()
        #expect(NSDictionary(dictionary: await service(dir, alerts, comms: comms, entitled: true).handle(request)) == ["ok": true])
        #expect(comms.sent.map(\.0) == ["z-iris-work-7"] && comms.sent[0].1 == sender && alerts.sent.isEmpty)
        #expect(URLStore(url: dir.appendingPathComponent("urls.json")).pop("z-iris-work-7") == "zulip://h/#narrow/dm/9")
    }

    @Test func plainAlertsWhenCommsFailsOrIsNotEntitledOrTheSenderIsMalformed() async {
        var request = show
        request["sender"] = sender.toJSON()
        let failing = FakeAlerts()
        let reply = await service(folder(), failing, comms: Comms(fail: "no entitlement"), entitled: true).handle(request)
        #expect(NSDictionary(dictionary: reply) == ["ok": true, "plain": "no entitlement"] && failing.sent.count == 1)

        let unentitled = FakeAlerts(), comms = Comms()
        let plain = await service(folder(), unentitled, comms: comms, entitled: false).handle(request)
        #expect((plain["plain"] as? String)?.contains("entitlement") == true && comms.sent.isEmpty && unentitled.sent.count == 1)

        request["sender"] = ["handle": 1]
        let malformed = FakeAlerts(), unused = Comms()
        #expect(NSDictionary(dictionary: await service(folder(), malformed, comms: unused, entitled: true).handle(request)) == ["ok": true])
        #expect(unused.sent.isEmpty && malformed.sent.count == 1)
    }
}

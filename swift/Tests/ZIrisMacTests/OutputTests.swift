import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

private let config = try! parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n", sounds: ["chime": "/c.wav"])

private func note(_ id: Int = 1, banner: String = "full", sticky: Bool = false, stay: Int = 0,
                  summary: String? = nil, kind: Message.Kind = .dm) -> ZIrisCore.Notification {
    let message = Message(server: "w", host: "h", id: id, kind: kind, senderID: 9, senderName: "Ada",
                          content: "hi **there**", flags: [], channelID: kind == .channel ? 7 : nil,
                          channelName: kind == .channel ? "ops" : nil, topic: kind == .channel ? "t" : nil,
                          dmUserIDs: kind == .dm ? [9] : [], avatarURL: "https://x/av.png")
    var action = Action(sound: "none", volume: 0, banner: banner, rule: nil)
    action.sticky = sticky
    action.stay = stay
    return ZIrisCore.Notification(message: message, url: narrowURL(message), reason: "dm", action: action, summary: summary)
}

private func output(priority: PriorityLink? = nil, fallback: FakeFallback) -> RealOutput {
    RealOutput(
        config: { config }, notifier: fallback, priority: priority,
        images: { _ in MessageImages(avatar: "/c/av.png", picture: "/c/pic.png") },
        player: SoundPlayer(), flasher: nil
    )
}

private func priorityLink(_ child: FakeChild, fallback: FakeFallback) throws -> PriorityLink {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-\(UUID().uuidString)/z-iris-priority.app")
    try FileManager.default.createDirectory(at: priorityExecutable(app).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: priorityExecutable(app))
    return PriorityLink(fallback: fallback, app: app, start: { _ in child }, warn: { _ in }, timeout: 1)
}

@Suite struct OutputTests {
    @Test func aBannerCarriesTheTextPictureAndSender() async {
        let banners = FakeFallback()
        let out = output(fallback: banners)
        out.deliver(note())
        await out.drain()
        let shown = banners.shown[0]
        #expect((shown.title, shown.body, shown.group) == ("Ada", "hi there", "z-iris-w-1"))
        #expect(shown.image == "/c/pic.png")
        #expect(shown.sender?.avatar == "/c/av.png" && shown.sender?.picture == "/c/pic.png")
    }

    @Test func titleOnlyHasNoTextOrPictureAndASummaryNoSender() async {
        let banners = FakeFallback()
        let out = output(fallback: banners)
        out.banner(note(banner: "title"))
        out.banner(note(2, summary: "3 new in #ops"))
        out.banner(note(3, banner: "off"))
        await out.drain()
        #expect(banners.shown.count == 2)
        #expect(banners.shown[0].body == "New message" && banners.shown[0].image == nil && banners.shown[0].sender?.picture == nil)
        #expect(banners.shown[1].title == "3 new in #ops" && banners.shown[1].sender == nil)
    }

    @Test func stickyGoesToThePriorityHelperAndReadsClearIt() async throws {
        let banners = FakeFallback()
        let child = FakeChild()
        let out = output(priority: try priorityLink(child, fallback: banners), fallback: banners)
        out.banner(note(sticky: true))
        out.banner(note(2))
        out.clearRead(server: "w", ids: [2, 1])
        out.clearRead(server: "w", ids: nil)
        out.clearUnlessUnread(server: "w", unread: [5])
        await out.drain()
        #expect(banners.shown.map(\.group) == ["z-iris-w-2"])
        let ops = child.requests.map { $0["op"] as! String }
        #expect(ops == ["status", "show", "clear", "clear_server", "clear_server"])
        #expect(child.requests[2]["groups"] as? [String] == ["z-iris-w-1", "z-iris-w-2"])
        #expect(child.requests[4]["keep"] as? [Int] == [5])
    }

    @Test func anAlertThatStaysIsClearedWhenItsTimeIsUp() async throws {
        let banners = FakeFallback()
        let child = FakeChild()
        let out = output(priority: try priorityLink(child, fallback: banners), fallback: banners)
        out.banner(note(stay: 1))
        await out.drain()
        try await Task.sleep(for: .milliseconds(1300))
        await out.drain()
        #expect(child.requests.map { $0["op"] as! String } == ["status", "show", "clear"])
    }

    @Test func withoutTheHelperReadsDoNothing() async {
        let banners = FakeFallback()
        let out = output(fallback: banners)
        out.clearRead(server: "w", ids: [1])
        out.banner(note(sticky: true))  // shown as an ordinary banner
        await out.drain()
        #expect(banners.shown.count == 1)
    }

    @Test func theDryRunDescribes() {
        let lines = Lines()
        let dry = DryRunOutput(player: ["play", "-q"], write: { lines.add($0) })
        dry.deliver(note())
        dry.clearRead(server: "w", ids: [1, 2])
        dry.clearUnlessUnread(server: "w", unread: [])
        #expect(lines.all[0].hasPrefix("[dry-run] w (dm): Ada\n"))
        #expect(lines.all[1] == "[dry-run] w: clear sticky alerts for 2 read messages")
        #expect(lines.all[2] == "[dry-run] w: clear sticky alerts except 0 unread")
    }
}

struct FakeSummarizer: Summarizer {
    var reply: String?
    var delay = 0.0
    func summarize(_ messages: [Message]) async -> String? {
        try? await Task.sleep(for: .seconds(delay))
        return reply.map { "\($0) (\(messages.count))" }
    }
}

@Suite struct SummaryOutputTests {
    private func summary(summarize: Bool = true, banner: String = "full") -> ZIrisCore.Notification {
        var n = note(3, banner: banner, summary: "3 new from Ada")
        n.action.summarize = summarize
        n.batch = [note(1).message, note(2).message, note(3).message]
        return n
    }

    private func run(_ summarizer: FakeSummarizer?, _ notification: ZIrisCore.Notification, timeout: Double = 1) async -> [(String, String)] {
        let banners = FakeFallback()
        let out = RealOutput(config: { config }, notifier: banners, priority: nil, images: nil, player: SoundPlayer(),
                             flasher: nil, summarizer: summarizer, summaryTimeout: timeout)
        out.banner(notification)
        await out.drain()
        try? await Task.sleep(for: .milliseconds(300))
        await out.drain()
        return banners.shown.map { ($0.group ?? "", $0.body) }
    }

    @Test func theModelsSentenceReplacesTheSummaryInPlace() async {
        let shown = await run(FakeSummarizer(reply: "Ada on deploys"), summary())
        #expect(shown.map(\.1) == ["hi there", "Ada on deploys (3)"])
        #expect(shown[0].0 == shown[1].0)
    }

    @Test func otherwiseThePlainSummaryStays() async {
        #expect(await run(FakeSummarizer(reply: "x"), summary(summarize: false)).count == 1)
        #expect(await run(FakeSummarizer(reply: nil), summary()).count == 1)
        #expect(await run(nil, summary()).count == 1)
        #expect(await run(FakeSummarizer(reply: "x"), summary(banner: "title")).count == 1)
        #expect(await run(FakeSummarizer(reply: "late", delay: 2), summary(), timeout: 0.1).count == 1)
    }
}

@Suite struct ConversationOutputTests {
    private let key = TopicKey(server: "w", channelID: 7, topic: "t")

    private func joined(_ id: Int) -> ZIrisCore.Notification {
        var n = note(id, kind: .channel)
        n.conversation = key
        return n
    }

    @Test func summaryReplacesSingles() async {
        let banners = FakeFallback()
        let out = output(fallback: banners)
        out.deliver(joined(1))
        out.conversationSummary(key, [joined(1), joined(2), joined(3)])
        out.clearConversation(key)
        await out.drain()
        #expect(banners.threads == ["w:channel:7:t", "w:channel:7:t"])
        #expect(banners.shown.count == 2)
        let summary = banners.shown[1]
        let group = "z-iris-conversation-w-7-8efd86fb78a5"  // sha1("t")
        #expect((summary.title, summary.body, summary.group) == ("3 new in #ops > t", "hi there", group))
        #expect(summary.sender == nil)
        #expect(banners.cleared == ["z-iris-w-1", "z-iris-w-2", "z-iris-w-3", group])
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

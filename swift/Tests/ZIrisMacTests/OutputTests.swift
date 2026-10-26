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

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
}

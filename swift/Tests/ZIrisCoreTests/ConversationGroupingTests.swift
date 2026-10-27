import Foundation
import Testing
@testable import ZIrisCore

final class Recorder: EngineOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var calls: [String] { lock.withLock { all } }
    private func add(_ call: String) { lock.withLock { all.append(call) } }

    func deliver(_ n: ZIrisCore.Notification) { add("deliver \(n.message.id) \(n.action.banner)") }
    func banner(_ n: ZIrisCore.Notification) { add("banner \(n.message.id)") }
    func sound(_ n: ZIrisCore.Notification, volume: Int?) { add("sound \(n.message.id)") }
    func clearRead(server: String, ids: Set<Int>?) { add("clear_read") }
    func clearUnlessUnread(server: String, unread: Set<Int>) { add("clear_unless") }
    func conversationSummary(_ key: TopicKey, _ unread: [ZIrisCore.Notification]) {
        add("summary \(unread.map(\.message.id))")
    }
    func clearConversation(_ key: TopicKey) { add("clear_conversation \(key.topic)") }
}

private let key = TopicKey(server: "w", channelID: 7, topic: "T")

private func joined(_ id: Int) -> ZIrisCore.Notification {
    let message = Message(server: "w", host: "h", id: id, kind: .channel, senderID: 9, senderName: "Ada", content: "hi",
                          flags: [], channelID: 7, channelName: "ops", topic: "T", dmUserIDs: [])
    var n = ZIrisCore.Notification(message: message, url: "u", reason: "conversation",
                                   action: Action(sound: "none", volume: 0, banner: "full", rule: nil))
    n.conversation = key
    return n
}

private func engine(_ output: Recorder) -> Engine {
    let config = try! parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n", sounds: ["chime": "/c.wav"])
    return Engine(output: output, config: { config }, isPaused: { false }, clock: { 0 },
                  scheduler: TestScheduler(), localMinutes: { 0 })
}

@Suite struct ConversationGroupingTests {
    @Test func firstThreeSeparateThenSummary() async {
        let out = Recorder()
        let e = engine(out)
        for id in 1...5 { await e.submit(joined(id)) }
        #expect(out.calls == [
            "deliver 1 full", "deliver 2 full", "deliver 3 full",
            "deliver 4 off", "summary [1, 2, 3, 4]", "deliver 5 off", "summary [1, 2, 3, 4, 5]",
        ])
    }

    @Test func readingClearsAndResets() async {
        let out = Recorder()
        let e = engine(out)
        for id in 1...4 { await e.submit(joined(id)) }
        await e.handle(server: "w", .read([1]))
        #expect(!out.calls.contains("clear_conversation t"))  // three still unread
        await e.handle(server: "w", .read([2, 3, 4]))
        #expect(out.calls.suffix(2) == ["clear_conversation t", "clear_read"])
        await e.submit(joined(6))
        #expect(out.calls.last == "deliver 6 full")  // single again
        await e.reconcileUnread(server: "w", unread: [])
        #expect(out.calls.suffix(2) == ["clear_conversation t", "clear_unless"])
    }
}

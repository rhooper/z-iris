import Foundation
import Testing
@testable import ZIrisCore

private func message(_ id: Int, _ sender: String, _ content: String, channel: String? = "ops", topic: String = "deploys") -> Message {
    Message(server: "w", host: "h", id: id, kind: channel == nil ? .dm : .channel, senderID: id, senderName: sender,
            content: content, flags: [], channelID: channel == nil ? nil : 7, channelName: channel,
            topic: channel == nil ? nil : topic, dmUserIDs: channel == nil ? [id] : [])
}

@Suite struct SummarizerTests {
    @Test func thePromptNamesThePlaceAndKeepsTheNewestWithinBudget() {
        let messages = [message(1, "Ada", "**deploy** failed"), message(2, "Bob", "rolling back :+1:")]
        #expect(summaryPrompt(messages) == "Messages in #ops > deploys:\nAda: deploy failed\nBob: rolling back 👍")
        let mixed = [message(1, "Ada", "hi"), message(2, "Cy", "yo", channel: nil)]
        #expect(summaryPrompt(mixed).hasPrefix("Messages in several conversations:"))
        let many = (1...50).map { message($0, "P\($0)", String(repeating: "x", count: 100)) }
        let prompt = summaryPrompt(many, budget: 500)
        #expect(prompt.hasSuffix("P50: " + String(repeating: "x", count: 100)))
        #expect(!prompt.contains("P1:") && prompt.count < 700)
    }

    @Test func theReplyBecomesOneShortLine() {
        #expect(summaryText("  \"Ada says the deploy\nfailed; Bob rolls back.\"  ") == "Ada says the deploy failed; Bob rolls back.")
        #expect(summaryText("   ") == nil)
        let long = summaryText(String(repeating: "word ", count: 100))!
        #expect(long.unicodeScalars.count == 200 && long.hasSuffix("…"))
    }

    @Test func aBatchSummaryCarriesItsHeldMessages() async throws {
        let scheduler = TestScheduler()
        let held = HeldMessages()
        let config = try parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n", sounds: ["chime": "/c.wav"])
        let engine = Engine(output: held, config: { config }, isPaused: { false }, clock: { scheduler.now }, scheduler: scheduler)
        for id in 1...3 {
            var action = Action(sound: "none", volume: 0, banner: "full", rule: nil)
            action.batchWindow = 5
            let m = message(id, "Ada", "m\(id)")
            await engine.submit(Notification(message: m, url: narrowURL(m), reason: "rule", action: action))
        }
        await scheduler.advance(6)
        #expect(held.summaries == [[2, 3]])  // the first message played; the rest were held
    }
}

final class HeldMessages: EngineOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [[Int]] = []
    var summaries: [[Int]] { lock.withLock { found } }
    func deliver(_ notification: ZIrisCore.Notification) {}
    func banner(_ notification: ZIrisCore.Notification) {
        if notification.summary != nil { lock.withLock { found.append(notification.batch.map(\.id)) } }
    }
    func sound(_ notification: ZIrisCore.Notification, volume: Int?) {}
    func clearRead(server: String, ids: Set<Int>?) {}
    func clearUnlessUnread(server: String, unread: Set<Int>) {}
}

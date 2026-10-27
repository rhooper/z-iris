import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

// Runs only with Z_IRIS_TRY_MODEL set: it uses the real on-device model.
@Suite struct ModelSummarizerTrial {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["Z_IRIS_TRY_MODEL"] != nil))
    func summarizesASampleBatch() async throws {
        let lines = [("Priya", "lunch order going in at 11:45, reply with what you want"), ("Tom", "pad thai for me please"),
                     ("Ines", "same, but no peanuts :peanuts:"), ("Priya", "also the offsite moved to Thursday the 12th"),
                     ("Tom", "Thursday works, I'll book the room")]
        let messages = lines.enumerated().map { index, line in
            Message(server: "w", host: "h", id: index, kind: .channel, senderID: index, senderName: line.0, content: line.1,
                    flags: [], channelID: 7, channelName: "team", topic: "friday", dmUserIDs: [])
        }
        print("available:", ModelSummarizer.available)
        let text = await ModelSummarizer().summarize(messages)
        print("summary:", text ?? "nil")
        #expect(text != nil)
    }
}

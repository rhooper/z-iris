import Foundation
import FoundationModels
import ZIrisCore

// Batch summaries from Apple's on-device model (Foundation Models, macOS 26).
// Nothing leaves the Mac. nil whenever the model is unavailable, refuses or
// fails: the plain "3 new in #ops" summary then stays.

public struct ModelSummarizer: Summarizer {
    private static let instructions = """
        You summarize a burst of chat messages for a phone-style notification. \
        Write one sentence of at most 20 words giving the gist: what happened, what is being asked or decided. \
        Name people only when it matters. Do not quote the messages, do not start with "New messages" \
        or mention Zulip, and use no markdown.
        Example: Deploy failed on a table lock; Ada wants to retry after 6pm and Cy is holding the release notes.
        """

    public init() {}

    /// Whether the model can be used now (Apple Intelligence on and ready).
    public static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func summarize(_ messages: [Message]) async -> String? {
        guard Self.available, !messages.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let reply = try await session.respond(to: summaryPrompt(messages))
            return summaryText(reply.content)
        } catch {
            return nil
        }
    }
}

import Testing
@testable import ZIrisCore

private func message(_ kind: Message.Kind, ids: [Int] = []) -> Message {
    Message(server: "w", host: "h", id: 1, kind: kind, senderID: 9, senderName: "Ada", content: "hi", flags: [],
            channelID: kind == .channel ? 7 : nil, channelName: kind == .channel ? "ops" : nil,
            topic: kind == .channel ? "Deploy Day" : nil, dmUserIDs: ids)
}

@Suite struct ThreadTests {
    @Test func aMessagesThreadIsItsTopicOrDM() {
        #expect(messageThread(message(.channel)) == "w:channel:7:Deploy Day")
        #expect(messageThread(message(.dm, ids: [9])) == "w:dm:9")
        #expect(messageThread(message(.dm, ids: [9, 10])) == "w:dm:9,10")
    }
}

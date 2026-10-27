import Foundation
import Testing
@testable import ZIrisCore

final class Clock2: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { value } }
    func advance(hours: Double) { lock.withLock { value = value.addingTimeInterval(hours * 3600) } }
}

private func file() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-joined-\(UUID().uuidString)/joined.json")
}

@Suite struct ConversationsTests {
    private let key = TopicKey(server: "work", channelID: 7, topic: "onboarding kristy")

    @Test func joiningAndExpiry() {
        let clock = Clock2()
        let store = Conversations(file: nil, hours: { 48 }, now: { clock.now })
        #expect(!store.isJoined(key))
        store.join(key)
        #expect(store.isJoined(key))
        clock.advance(hours: 40)
        store.touch(key)
        clock.advance(hours: 40)
        #expect(store.isJoined(key))  // 40 h since the last activity
        clock.advance(hours: 8)
        #expect(!store.isJoined(key))  // 48 h of quiet
        store.touch(key)
        #expect(!store.isJoined(key))  // touch never joins
    }

    @Test func caseInsensitiveTopics() {
        let store = Conversations(file: nil, hours: { 48 })
        store.join(TopicKey(server: "work", channelID: 7, topic: "Onboarding Kristy"))
        #expect(store.isJoined(key))
        #expect(!store.isJoined(TopicKey(server: "work", channelID: 8, topic: "onboarding kristy")))
        #expect(!store.isJoined(TopicKey(server: "home", channelID: 7, topic: "onboarding kristy")))
    }

    @Test func ownMessagesAndMoves() {
        let store = Conversations(file: nil, hours: { 48 })
        store.recordOwn(OwnMessage(id: 40, kind: .channel, place: key, snippet: "welcome!"))
        store.join(key)
        #expect(store.own(40)?.snippet == "welcome!")
        #expect(store.own(41) == nil)
        let moved = TopicKey(server: "work", channelID: 9, topic: "kristy week 1")
        store.move(messageID: 40, to: moved)
        #expect(store.isJoined(moved) && !store.isJoined(key))
        #expect(store.own(40)?.place == moved)
        for id in 1000..<1600 { store.recordOwn(OwnMessage(id: id, kind: .dm, place: nil, snippet: "")) }
        #expect(store.own(1000) == nil && store.own(1599) != nil)  // the newest 500
    }

    @Test func survivesRestartAndCorruption() throws {
        let path = file()
        let clock = Clock2()
        Conversations(file: path, hours: { 48 }, now: { clock.now }).join(key)
        #expect(Conversations(file: path, hours: { 48 }, now: { clock.now }).isJoined(key))
        clock.advance(hours: 49)
        #expect(!Conversations(file: path, hours: { 48 }, now: { clock.now }).isJoined(key))
        try "{".write(to: path, atomically: true, encoding: .utf8)
        let fresh = Conversations(file: path, hours: { 48 })
        #expect(!fresh.isJoined(key))
    }
}

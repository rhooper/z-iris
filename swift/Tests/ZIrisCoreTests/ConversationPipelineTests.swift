import Foundation
import Testing
@testable import ZIrisCore

private let me = 5

private func config(_ text: String) -> Config {
    try! parseConfig("[[server]]\nname = \"work\"\nzuliprc = \"/x\"\n" + text, sounds: ["chime": "/c.wav", "ping": "/p.wav"])
}

private func event(id: Int, from sender: Int = 9, channel: String = "python", topic: String = "onboarding kristy",
                   flags: [String] = []) -> [String: Any] {
    ["type": "message", "flags": flags, "message": [
        "id": id, "sender_id": sender, "sender_full_name": sender == me ? "Me" : "Ada", "content": "hi",
        "type": "stream", "stream_id": channel == "python" ? 7 : 8, "display_recipient": channel, "subject": topic,
    ] as [String: Any]]
}

private func pipeline(_ config: Config, mutes: MuteState = MuteState()) -> (Pipeline, Conversations) {
    let store = Conversations(file: nil, hours: { config.joinedHours })
    return (Pipeline(server: "work", host: "chat.example.com", selfID: me, mutes: mutes,
                     config: { config }, conversations: store), store)
}

private let kristy = TopicKey(server: "work", channelID: 7, topic: "Onboarding Kristy")

@Suite struct ConversationPipelineTests {
    @Test func postingJoinsAndRepliesAlert() throws {
        var (p, store) = pipeline(config("[defaults]\nnotify_channel_messages = false\n"))
        #expect(p.handle(event(id: 1)) == nil)  // not joined yet
        #expect(p.handle(event(id: 2, from: me)) == nil)
        #expect(store.isJoined(kristy) && store.own(2) != nil)
        let replyGot = p.handle(event(id: 3))
        let reply = try #require(replyGot)
        #expect(reply.reason == "conversation" && reply.action.sticky && reply.conversation == kristy)
        #expect(p.handle(event(id: 4, topic: "other")) == nil)
    }

    @Test func mentionJoinsWhenConfigured() {
        var (p, store) = pipeline(config("[defaults]\nnotify_channel_messages = false\n"))
        #expect(p.handle(event(id: 1, flags: ["mentioned"]))?.reason == "mention")
        #expect(store.isJoined(kristy))
        var (off, offStore) = pipeline(config("[defaults]\nnotify_channel_messages = false\njoin_on_mention = false\n"))
        _ = off.handle(event(id: 1, flags: ["mentioned"]))
        #expect(!offStore.isJoined(kristy))
    }

    @Test func ruleJoin() {
        var (p, store) = pipeline(config("""
        [defaults]
        join_on_mention = false
        [[rule]]
        match = "topic"
        topic = "onboarding"
        join = true
        """))
        _ = p.handle(event(id: 1))
        #expect(store.isJoined(kristy))
        _ = p.handle(event(id: 2, topic: "lunch"))
        #expect(!store.isJoined(TopicKey(server: "work", channelID: 7, topic: "lunch")))
    }

    @Test func silencedChannelStillAlertsWithoutSound() throws {
        var (p, store) = pipeline(config("""
        [[rule]]
        match = "channel"
        channel = "python"
        sound = "none"
        banner = "off"
        """))
        store.join(kristy)
        let nGot = p.handle(event(id: 1))
        let n = try #require(nGot)
        #expect(n.action.banner == "full" && n.action.sound == "none" && n.reason == "conversation")
        #expect(p.handle(event(id: 2, topic: "lunch")) == nil)  // still silenced elsewhere
    }

    @Test func conversationRuleLayersOnTop() throws {
        var (p, store) = pipeline(config("""
        [[rule]]
        match = "channel"
        channel = "python"
        sound = "ping"
        [[rule]]
        match = "conversation"
        sticky = false
        """))
        store.join(kristy)
        let nGot = p.handle(event(id: 1))
        let n = try #require(nGot)
        #expect(n.action.sound == "/p.wav" && !n.action.sticky && n.conversation == kristy)
    }

    @Test func mutedTopicStaysSilent() throws {
        let mutes = try MuteState(register: ["user_topics": [
            ["stream_id": 7, "topic_name": "onboarding kristy", "visibility_policy": 1],
        ]])
        var (p, store) = pipeline(config(""), mutes: mutes)
        store.join(kristy)
        #expect(p.handle(event(id: 1)) == nil)
    }

    @Test func focusLetsConversationsThrough() async throws {
        let c = config("[focus]\nmode = \"mentions_and_dms\"\n")
        var (p, store) = pipeline(c)
        store.join(kristy)
        let nGot = p.handle(event(id: 1))
        let n = try #require(nGot)
        let scheduler = TestScheduler()
        let trace = Trace(clock: { scheduler.now })
        let engine = Engine(output: trace, config: { c }, isPaused: { false }, clock: { scheduler.now },
                            scheduler: scheduler, localMinutes: { 0 }, log: { _ in })
        await engine.submit(n)
        #expect(trace.entries.contains { $0["call"] as? String == "deliver" })
    }

    @Test func noConversationsMeansToday() {
        var p = Pipeline(server: "work", host: "chat.example.com", selfID: me, mutes: MuteState(),
                         config: { config("[defaults]\nnotify_channel_messages = false\n") }, conversations: nil)
        #expect(p.handle(event(id: 1, from: me)) == nil)
        #expect(p.handle(event(id: 2)) == nil)
    }
}

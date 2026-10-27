import Foundation
import Testing
@testable import ZIrisCore

private let me = 5

private func config(_ text: String) -> Config {
    try! parseConfig("[[server]]\nname = \"work\"\nzuliprc = \"/x\"\n" + text,
                     sounds: ["chime": "/c.wav", "ping": "/p.wav", "soft": "/s.wav"])
}

private func reaction(_ message: Int = 2, by user: Int = 9, name: String? = "Ada", emoji: String = "thumbs_up",
                      code: String = "1f44d", type: String = "unicode_emoji", op: String = "add") -> [String: Any] {
    var event: [String: Any] = ["type": "reaction", "op": op, "message_id": message, "user_id": user,
                                "emoji_name": emoji, "emoji_code": code, "reaction_type": type]
    if let name {
        event["user"] = ["user_id": user, "full_name": name]
    }
    return event
}

private func pipeline(_ config: Config) -> (Pipeline, Conversations) {
    let store = Conversations(file: nil, hours: { 48 })
    store.recordOwn(OwnMessage(id: 2, kind: .channel, place: TopicKey(server: "work", channelID: 7, topic: "onboarding kristy"),
                               snippet: "I'll pair with Kristy", channelName: "python", topic: "onboarding kristy"))
    store.recordOwn(OwnMessage(id: 3, kind: .dm, place: nil, snippet: "see you", dmUserIDs: [9]))
    return (Pipeline(server: "work", host: "chat.example.com", selfID: me, mutes: MuteState(),
                     config: { config }, conversations: store), store)
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct ReactionTests {
    @Test func parsesReactionEvents() throws {
        let thumbs = try #require(ReactionEvent(reaction()))
        #expect(thumbs == ReactionEvent(messageID: 2, userID: 9, userName: "Ada", emojiName: "thumbs_up", emoji: "👍", added: true))
        #expect(ReactionEvent(reaction(emoji: "technologist", code: "1f468-200d-1f4bb"))?.emoji == "👨‍💻")
        #expect(ReactionEvent(reaction(emoji: "party_parrot", code: "123", type: "realm_emoji"))?.emoji == ":party_parrot:")
        #expect(ReactionEvent(reaction(name: nil))?.userName == "Someone")
        #expect(ReactionEvent(reaction(op: "remove"))?.added == false)
        #expect(ReactionEvent(["type": "message"]) == nil)
    }

    @Test func notifiesOnlyForOthersAddingToYours() throws {
        let (p, _) = pipeline(config(""))
        #expect(p.handleReaction(try #require(ReactionEvent(reaction(by: me))), now: t0) == nil)
        #expect(p.handleReaction(try #require(ReactionEvent(reaction(op: "remove"))), now: t0) == nil)
        #expect(p.handleReaction(try #require(ReactionEvent(reaction(99))), now: t0) == nil)
        let n = p.handleReaction(try #require(ReactionEvent(reaction())), now: t0)
        #expect(n?.reason == "reaction" && n?.message.content == "I'll pair with Kristy")
        #expect(n.map(notificationTitle) == "Ada reacted 👍 to your message in #python > onboarding kristy")
        let dm = p.handleReaction(try #require(ReactionEvent(reaction(3))), now: t0)
        #expect(dm.map(notificationTitle) == "Ada reacted 👍 to your message in a direct message")
        #expect(dm?.url == "zulip://chat.example.com/#narrow/dm/9-pm/with/3")
    }

    @Test func titleAndGrouping() throws {
        let (p, _) = pipeline(config(""))
        let first = p.handleReaction(try #require(ReactionEvent(reaction())), now: t0)
        let second = p.handleReaction(try #require(ReactionEvent(reaction(by: 10, name: "Bob", emoji: "tada", code: "1f389"))),
                                      now: t0 + 30)
        #expect(second.map(notificationTitle) == "Ada and Bob reacted 👍🎉 to your message in #python > onboarding kristy")
        #expect(first?.group == "z-iris-reaction-work-2" && second?.group == first?.group)
        let third = p.handleReaction(try #require(ReactionEvent(reaction(by: 11, name: "Cy"))), now: t0 + 40)
        #expect(third.map(notificationTitle) == "Ada and 2 others reacted 👍🎉 to your message in #python > onboarding kristy")
        let fresh = p.handleReaction(try #require(ReactionEvent(reaction(by: 10, name: "Bob", emoji: "tada", code: "1f389"))),
                                     now: t0 + 101)
        #expect(fresh.map(notificationTitle) == "Bob reacted 🎉 to your message in #python > onboarding kristy")
    }

    @Test func silentByDefaultRuleRings() throws {
        let (p, _) = pipeline(config("[defaults]\nsound = \"chime\"\n"))
        let quiet = p.handleReaction(try #require(ReactionEvent(reaction())), now: t0)
        #expect(quiet?.action.sound == "none" && quiet?.action.banner == "full")
        let (ringing, _) = pipeline(config("""
        [[rule]]
        match = "reaction"
        sound = "ping"
        [[rule]]
        match = "channel"
        channel = "python"
        priority = 1
        sound = "chime"
        [rule.reaction]
        volume = 40
        """))
        let sub = ringing.handleReaction(try #require(ReactionEvent(reaction())), now: t0)
        #expect(sub?.action.sound == "/c.wav" && sub?.action.volume == 40)  // the sub-rule inherits its parent's sound
        let dm = ringing.handleReaction(try #require(ReactionEvent(reaction(3))), now: t0)
        #expect(dm?.action.sound == "/p.wav")
    }

    @Test func reactionsOff() throws {
        let (p, _) = pipeline(config("[defaults]\nreactions = false\n"))
        #expect(p.handleReaction(try #require(ReactionEvent(reaction())), now: t0) == nil)
    }

    @Test func focusDropsReactions() async throws {
        let c = config("[focus]\nmode = \"mentions_and_dms\"\n")
        let (p, _) = pipeline(c)
        let event = try #require(ReactionEvent(reaction(3)))
        let n = try #require(p.handleReaction(event, now: t0))
        let scheduler = TestScheduler()
        let trace = Trace(clock: { scheduler.now })
        let engine = Engine(output: trace, config: { c }, isPaused: { false }, clock: { scheduler.now },
                            scheduler: scheduler, localMinutes: { 0 }, log: { _ in })
        await engine.submit(n)
        #expect(!trace.entries.contains { $0["call"] as? String == "deliver" })
    }
}

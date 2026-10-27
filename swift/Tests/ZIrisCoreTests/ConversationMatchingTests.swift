import Foundation
import Testing
@testable import ZIrisCore

private let sounds = ["chime": "/c.wav", "ping": "/p.wav", "soft": "/s.wav", "bell": "/b.wav"]

private func config(_ body: String, defaults: String = "") -> Config {
    try! parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n[defaults]\n" + defaults + "\n" + body, sounds: sounds)
}

private func message(channel: String = "python", topic: String = "onboarding kristy", flags: Set<String> = []) -> Message {
    Message(server: "w", host: "h", id: 1, kind: .channel, senderID: 9, senderName: "Ada", content: "hi", flags: flags,
            channelID: 7, channelName: channel, topic: topic, dmUserIDs: [])
}

private let python = ReactionPlace(server: "w", channelName: "python", topic: "onboarding kristy", isDM: false)

@Suite struct ConversationMatchingTests {
    @Test func conversationRulesNeverCompete() {
        let rules = config("[[rule]]\nmatch = \"conversation\"\npriority = 9\n").rules
        #expect(pickRule(rules, message()) == nil)
        let reactions = config("[[rule]]\nmatch = \"reaction\"\n").rules
        #expect(pickRule(reactions, message()) == nil)
    }

    @Test func conversationRuleFiltersByPlace() {
        let rules = config("""
        [[rule]]
        match = "conversation"
        channel = "python"
        description = "python"
        [[rule]]
        match = "conversation"
        description = "anywhere"
        [[rule]]
        match = "conversation"
        topic = "release"
        priority = 5
        description = "releases"
        """).rules
        #expect(conversationRule(rules, message())?.description == "python")
        #expect(conversationRule(rules, message(channel: "ops"))?.description == "anywhere")
        #expect(conversationRule(rules, message(topic: "Release 2.0"))?.description == "releases")
        #expect(conversationRule([], message()) == nil)
    }

    @Test func reactionRuleAndSubRule() {
        let rules = config("""
        [[rule]]
        match = "reaction"
        description = "any reaction"
        [[rule]]
        match = "reaction"
        emoji = ["tada"]
        priority = 2
        description = "tada"
        [[rule]]
        match = "channel"
        channel = "python"
        priority = 1
        [rule.reaction]
        sound = "soft"
        """).rules
        #expect(pickReactionRule(rules, place: python, emoji: "+1")?.rule.sound == "soft")  // the sub-rule, priority 1
        #expect(pickReactionRule(rules, place: python, emoji: "+1")?.parent?.kind == .channel)
        #expect(pickReactionRule(rules, place: python, emoji: "tada")?.rule.description == "tada")
        let ops = ReactionPlace(server: "w", channelName: "ops", topic: "x", isDM: false)
        #expect(pickReactionRule(rules, place: ops, emoji: "+1")?.rule.description == "any reaction")
        let dm = ReactionPlace(server: "w", channelName: nil, topic: nil, isDM: true)
        #expect(pickReactionRule(rules, place: dm, emoji: "+1")?.rule.description == "any reaction")
        #expect(pickReactionRule([], place: dm, emoji: "+1") == nil)
    }

    @Test func layering() throws {
        let c = config("""
        [[rule]]
        match = "channel"
        channel = "python"
        sound = "ping"
        volume = 50
        [rule.reaction]
        volume = 20
        [[rule]]
        match = "conversation"
        channel = "ops"
        sticky = false
        sound = "bell"
        """, defaults: "sticky = false\nsound = \"bell\"\n")
        let channelRule = c.rules[0], conversation = c.rules[1]
        let joined = resolveAction(c, server: "w", rule: channelRule, layer: nil, layerBuiltIns: conversationBuiltIns)
        #expect(joined.sound == "/p.wav" && joined.sticky)  // [defaults] sticky = false does not unstick
        let layered = resolveAction(c, server: "w", rule: channelRule, layer: conversation, layerBuiltIns: conversationBuiltIns)
        #expect(!layered.sticky && layered.sound == "/b.wav")
        let reaction = resolveAction(c, server: "w", rule: nil, layer: nil, layerBuiltIns: [:], layerSound: "none")
        #expect(reaction.sound == "none")  // [defaults] sound = bell does not ring
        let sub = try #require(channelRule.reactionRule)
        let subAction = resolveAction(c, server: "w", rule: channelRule, layer: sub, layerBuiltIns: [:], layerSound: "none")
        #expect(subAction.sound == "/p.wav" && subAction.volume == 20)  // the parent's sound, as the spec says
        var ringing = sub
        ringing.sound = "soft"
        #expect(resolveAction(c, server: "w", rule: channelRule, layer: ringing, layerBuiltIns: [:], layerSound: "none").sound == "/s.wav")
        #expect(resolveAction(c, server: "w", rule: channelRule) == resolveAction(c, server: "w", rule: channelRule, layer: nil, layerBuiltIns: [:]))
    }
}

import Foundation
import Testing
@testable import ZIrisCore

private let sounds = ["chime": "/c.wav", "ping": "/p.wav", "soft": "/s.wav"]
private let server = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"

private func rule(_ body: String) -> String { server + "[[rule]]\n" + body }

@Suite struct ConversationConfigTests {
    @Test func newKindsAndKeysParse() throws {
        let config = try parseConfig(server + """
        [defaults]
        joined_hours = 24
        join_on_mention = false
        reactions = false
        group_after = 5

        [[rule]]
        match = "conversation"
        channel = "python"
        sticky = false

        [[rule]]
        match = "reaction"
        emoji = ["tada", "+1"]
        sound = "ping"

        [[rule]]
        match = "channel"
        channel = "python"
        join = true
        sound = "ping"

        [rule.reaction]
        sound = "soft"
        volume = 40
        """, sounds: sounds)
        #expect(config.joinedHours == 24 && !config.joinOnMention && !config.reactions)
        #expect(config.behaviour["group_after"] == .integer(5))
        #expect(config.rules.map(\.kind) == [.conversation, .reaction, .channel])
        #expect(config.rules[1].emoji == ["tada", "+1"])
        #expect(config.rules[2].join && !config.rules[0].join)
        let sub = try #require(config.rules[2].reactionRule)
        #expect(sub.kind == .reaction && sub.sound == "soft" && sub.volume == 40 && sub.index == 2)
        #expect(config.rules[0].reactionRule == nil)
        #expect(Config(servers: []).joinedHours == 48 && Config(servers: []).joinOnMention && Config(servers: []).reactions)
        #expect(resolveAction(config, server: "w", rule: nil).groupAfter == 5)
        #expect(resolveAction(try parseConfig(server, sounds: sounds), server: "w", rule: nil).groupAfter == 3)
        #expect(config.rules[0].label == "Conversation you're in #python")
        #expect(config.rules[1].label == "Reaction to your message")
    }

    @Test(arguments: [
        (rule("match = \"dm\"\njoin = 1\n"), "rule number 1: join must be true or false"),
        (rule("match = \"reaction\"\nemoji = 3\n"), "rule number 1: emoji must be an emoji name or a list of them"),
        (rule("match = \"dm\"\nemoji = \"tada\"\n"), "rule number 1: emoji only applies to reaction rules"),
        (rule("match = \"dm\"\n[rule.reaction]\nsound = \"soft\"\n"),
         "rule number 1: reaction settings only apply to channel, topic and conversation rules"),
        (rule("match = \"channel\"\nchannel = \"x\"\n[rule.reaction]\nmatch = \"dm\"\n"),
         "rule number 1: reaction settings cannot set match, channel, topic or keyword"),
        (rule("match = \"channel\"\nchannel = \"x\"\n[rule.reaction]\nvolume = 500\n"),
         "rule number 1: volume must be an integer from 0 to 100"),
        (server + "[defaults]\njoined_hours = 0\n", "joined_hours must be an integer from 1 to 720"),
        (server + "[defaults]\njoin_on_mention = 1\n", "join_on_mention must be true or false"),
        (server + "[defaults]\nreactions = \"yes\"\n", "reactions must be true or false"),
        (server + "[defaults]\ngroup_after = 21\n", "group_after must be from 1 to 20"),
    ])
    func refusals(_ text: String, _ message: String) {
        #expect(throws: ConfigError(message)) { try parseConfig(text, sounds: sounds) }
    }
}

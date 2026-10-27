import Foundation
import Testing
@testable import ZIrisCore

private let sounds = ["chime": "/c.wav", "ping": "/p.wav", "soft": "/s.wav"]
private let head = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"

@Suite struct ConversationEditingTests {
    @Test func subRuleRoundTrips() throws {
        let text = head + """

        [[rule]]
        match = "channel"
        channel = "python"
        sound = "ping"
        join = true

        [rule.reaction]
        sound = "soft"
        volume = 40

        [[rule]]
        match = "reaction"
        emoji = ["tada"]
        sound = "ping"

        """
        let editable = try readEditable(text)
        #expect(editable.rules[0]["reaction"] == .table([("sound", .string("soft")), ("volume", .integer(40))]))
        #expect(editable.rules[1]["emoji"] == .array([.string("tada")]))
        #expect(try applyEdit(text, payload: EditPayload(rules: editable.rules), sounds: sounds) == text)
    }

    @Test func addingAndRemovingASubRule() throws {
        let text = head + "\n[[rule]]\nmatch = \"channel\"\nchannel = \"python\"\n"
        var rules = try readEditable(text).rules
        rules[0]["reaction"] = .table([("sound", .string("soft"))])
        let added = try applyEdit(text, payload: EditPayload(rules: rules), sounds: sounds)
        #expect(added == text + "\n[rule.reaction]\nsound = \"soft\"\n")
        rules[0]["reaction"] = nil
        #expect(try applyEdit(added, payload: EditPayload(rules: rules), sounds: sounds) == text)
        rules[0]["reaction"] = .table([])  // an emptied section goes too
        #expect(try applyEdit(added, payload: EditPayload(rules: rules), sounds: sounds) == text)
    }

    @Test func newDefaultsWrite() throws {
        let text = head + "\n[defaults]\nsound = \"chime\"\n"
        let payload = EditPayload(defaults: [
            "group_after": .integer(5), "reactions": .bool(false), "joined_hours": .integer(24), "join_on_mention": .bool(false),
        ])
        let out = try applyEdit(text, payload: payload, sounds: sounds)
        #expect(out == text + "join_on_mention = false\njoined_hours = 24\nreactions = false\ngroup_after = 5\n")
        let back = try readEditable(out).defaults
        #expect(back["joined_hours"] == .integer(24) && back["group_after"] == .integer(5))
    }
}

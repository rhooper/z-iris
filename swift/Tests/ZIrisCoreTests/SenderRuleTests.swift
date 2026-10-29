import Foundation
import Testing
@testable import ZIrisCore

private let head = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"
private let sounds = ["chime": "/c.wav", "ping": "/p.wav"]

private func config(_ rules: String) throws -> Config {
    try parseConfig(head + rules, sounds: sounds)
}

private func message(from name: String = "Ada Lovelace", email: String = "ada@example.com",
                     channel: String? = "ops") -> Message {
    Message(server: "w", host: "h", id: 1, kind: channel == nil ? .dm : .channel, senderID: 9, senderName: name,
            content: "hi", flags: [], channelID: channel == nil ? nil : 7, channelName: channel, topic: channel == nil ? nil : "t",
            dmUserIDs: channel == nil ? [9] : [], senderEmail: email)
}

@Suite struct SenderRuleTests {
    @Test func parsesOneOrMany() throws {
        let one = try config("[[rule]]\nmatch = \"sender\"\nsender = \"Ada Lovelace\"\n").rules[0]
        #expect(one.kind == .sender && one.senders == ["Ada Lovelace"])
        #expect(one.label == "Sender Ada Lovelace")
        let many = try config("[[rule]]\nmatch = \"sender\"\nsender = [\"Ada Lovelace\", \"bob@example.com\"]\n").rules[0]
        #expect(many.senders == ["Ada Lovelace", "bob@example.com"])
        #expect(many.label == "Sender Ada Lovelace, bob@example.com")
    }

    @Test(arguments: [
        ("[[rule]]\nmatch = \"sender\"\n", "rule number 1: a sender rule needs sender"),
        ("[[rule]]\nmatch = \"dm\"\nsender = \"Ada\"\n", "rule number 1: sender only applies to sender rules"),
        ("[[rule]]\nmatch = \"sender\"\nsender = true\n", "rule number 1: sender must be a user ID, name or email, or a list of them"),
        ("[[rule]]\nmatch = \"sender\"\nsender = 0\n", "rule number 1: sender must be a user ID, name or email, or a list of them"),
        ("[[rule]]\nmatch = \"sender\"\nsender = []\n", "rule number 1: sender must be a user ID, name or email, or a list of them"),
        ("[[rule]]\nmatch = \"sender\"\nsender = [\"\"]\n", "rule number 1: sender must be a user ID, name or email, or a list of them"),
    ])
    func refusals(_ rules: String, _ error: String) {
        #expect(throws: ConfigError(error)) { try config(rules) }
    }

    @Test func matchesByNameOrEmailAnywhere() throws {
        let rules = try config("[[rule]]\nmatch = \"sender\"\nsender = [\"ada lovelace\", \"BOB@example.com\"]\nsound = \"ping\"\n").rules
        #expect(pickRule(rules, message()) != nil)  // name, any case
        #expect(pickRule(rules, message(from: "Bob", email: "bob@example.com")) != nil)  // email, any case
        #expect(pickRule(rules, message(channel: nil)) != nil)  // in a direct message too
        #expect(pickRule(rules, message(from: "Ada", email: "a@x")) == nil)  // whole names only
    }

    @Test func matchesUserIDs() throws {
        let rule = try config("[[rule]]\nmatch = \"sender\"\nsender = [9, \"bob@example.com\"]\n").rules[0]
        #expect(rule.senderIDs == [9] && rule.senders == ["bob@example.com"])
        #expect(rule.label == "Sender bob@example.com, #9")
        #expect(pickRule([rule], message(from: "Renamed", email: "new@x")) != nil)
        #expect(pickRule([rule], message(from: "Bob", email: "bob@example.com")) != nil)
    }

    @Test func userIDsNeedAServerWhenThereAreSeveral() throws {
        let two = head + "[[server]]\nname = \"v\"\nzuliprc = \"/y\"\n"
        #expect(throws: ConfigError("rule number 1: sender IDs need server when there is more than one server")) {
            try parseConfig(two + "[[rule]]\nmatch = \"sender\"\nsender = 9\n", sounds: sounds)
        }
        let named = try parseConfig(two + "[[rule]]\nmatch = \"sender\"\nsender = 9\nserver = \"w\"\n", sounds: sounds)
        #expect(named.rules[0].senderIDs == [9])
        // Names and emails need no server.
        #expect(try parseConfig(two + "[[rule]]\nmatch = \"sender\"\nsender = \"Ada\"\n", sounds: sounds).rules.count == 1)
    }

    @Test func aSenderRuleBeatsAChannelRule() throws {
        let rules = try config("""
        [[rule]]
        match = "channel"
        channel = "ops"
        sound = "chime"
        [[rule]]
        match = "sender"
        sender = "Ada Lovelace"
        sound = "ping"
        """).rules
        #expect(pickRule(rules, message())?.kind == .sender)
    }

    @Test func eventsCarryTheSendersEmail() throws {
        let event: [String: Any] = ["type": "message", "flags": [String](), "message": [
            "id": 1, "sender_id": 9, "sender_full_name": "Ada", "sender_email": "ada@example.com", "content": "hi",
            "type": "stream", "stream_id": 7, "display_recipient": "ops", "subject": "t",
        ] as [String: Any]]
        #expect(try Message(server: "w", host: "h", selfID: 5, event: event).senderEmail == "ada@example.com")
    }

    @Test func theEditorRoundTripsSenders() throws {
        let text = head + "\n[[rule]]\nmatch = \"sender\"\nsender = [\"Ada Lovelace\", \"bob@example.com\"]\n\n[[rule]]\nmatch = \"sender\"\nsender = \"Cy\"\n"
        let rules = try readEditable(text).rules
        #expect(rules[0]["sender"] == .array([.string("Ada Lovelace"), .string("bob@example.com")]))
        #expect(rules[1]["sender"] == .array([.string("Cy")]))
        #expect(try applyEdit(text, payload: EditPayload(rules: rules), sounds: sounds) == text)
        let ids = head + "\n[[rule]]\nmatch = \"sender\"\nsender = [9, \"Cy\"]\n"
        #expect(try readEditable(ids).rules[0]["sender"] == .array([.integer(9), .string("Cy")]))
        #expect(try applyEdit(ids, payload: EditPayload(rules: try readEditable(ids).rules), sounds: sounds) == ids)
    }
}

import Foundation
import Testing
@testable import ZIrisCore

private let head = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"
private let sounds = ["chime": "/c.wav", "ping": "/p.wav"]

private func config(_ rules: String, servers: String = head) throws -> Config {
    try parseConfig(servers + rules, sounds: sounds)
}

private func message(_ content: String = "deploy done", channel: String? = "ops", senderID: Int = 9, server: String = "w") -> Message {
    Message(server: server, host: "h", id: 1, kind: channel == nil ? .dm : .channel, senderID: senderID, senderName: "x",
            content: content, flags: [], channelID: channel == nil ? nil : 7, channelName: channel,
            topic: channel == nil ? nil : "t", dmUserIDs: channel == nil ? [senderID] : [])
}

@Suite struct ExceptionRuleTests {
    private let deploys = """
    [[rule]]
    match = "keyword"
    keyword = "deploy"
    sound = "ping"
    [[rule.except]]
    match = "sender"
    sender = 2213
    [[rule.except]]
    match = "channel"
    channel = "ops-noise"
    [[rule]]
    match = "channel"
    channel = "ops.*"
    sound = "chime"
    """

    @Test func anyExceptionPassesTheMessageOn() throws {
        let rules = try config(deploys).rules
        #expect(rules[0].exceptions.map(\.kind) == [.sender, .channel])
        #expect(rules[0].label == "Keyword /deploy/, except Sender #2213 or Channel #ops-noise")
        #expect(pickRule(rules, message())?.kind == .keyword)
        // Excepted: the next rule decides.
        #expect(pickRule(rules, message(senderID: 2213))?.kind == .channel)
        #expect(pickRule(rules, message(channel: "ops-noise"))?.kind == .channel)
        #expect(pickRule(rules, message(channel: "dev", senderID: 2213)) == nil)
    }

    @Test func exceptionsTakeTheRulesServer() throws {
        let two = head + "[[server]]\nname = \"v\"\nzuliprc = \"/y\"\n"
        let rules = try config("[[rule]]\nmatch = \"mention\"\nserver = \"w\"\n[[rule.except]]\nmatch = \"sender\"\nsender = 4\n",
                               servers: two).rules
        #expect(rules[0].exceptions[0].server == "w")
    }

    @Test(arguments: [
        ("[[rule]]\nmatch = \"mention\"\n[[rule.except]]\nmatch = \"sender\"\nsender = 4\nsound = \"ping\"\n",
         "rule number 1, exception 1: an exception cannot set sound"),
        ("[[rule]]\nmatch = \"mention\"\n[[rule.except]]\nmatch = \"conversation\"\n",
         "rule number 1, exception 1: match cannot be conversation or reaction"),
        ("[[rule]]\nmatch = \"conversation\"\n[[rule.except]]\nmatch = \"sender\"\nsender = 4\n",
         "rule number 1: exceptions do not apply to conversation and reaction rules"),
        ("[[rule]]\nmatch = \"mention\"\nexcept = 3\n", "rule number 1: exceptions must be tables, written [[rule.except]]"),
        ("[[rule]]\nmatch = \"mention\"\n[[rule.except]]\nmatch = \"topic\"\n", "rule number 1, exception 1: a topic rule needs topic"),
    ])
    func refusals(_ rules: String, _ error: String) {
        #expect(throws: ConfigError(error)) { try config(rules) }
    }
}

@Suite struct ExceptionEditingTests {
    @Test func theEditorRoundTripsExceptions() throws {
        let text = head + """

        [[rule]]
        match = "topic"
        topic = "deploy"
        sound = "ping"

        [rule.reaction]
        sound = "chime"

        [[rule.except]]
        match = "sender"
        sender = 2213

        [[rule.except]]
        match = "channel"
        channel = ["ops-noise", "ops-bots"]

        """
        let rules = try readEditable(text).rules
        #expect(rules[0]["except"] == .array([
            .table([("match", .string("sender")), ("sender", .integer(2213))]),
            .table([("match", .string("channel")), ("channel", .array([.string("ops-noise"), .string("ops-bots")]))]),
        ]))
        #expect(try applyEdit(text, payload: EditPayload(rules: rules), sounds: sounds) == text)
    }

    @Test func addingAndRemovingAnException() throws {
        let plain = head + "\n[[rule]]\nmatch = \"mention\"\n"
        var rule = try readEditable(plain).rules[0]
        rule["except"] = .array([.table([("match", .string("channel")), ("channel", .array([.string("random")]))])])
        let added = try applyEdit(plain, payload: EditPayload(rules: [rule]), sounds: sounds)
        #expect(added == plain + "\n[[rule.except]]\nmatch = \"channel\"\nchannel = \"random\"\n")
        rule["except"] = nil
        #expect(try applyEdit(added, payload: EditPayload(rules: [rule]), sounds: sounds) == plain)
    }
}

import Testing
import ZIrisCore

@Suite struct MessageParity {
    @Test(arguments: Fixture.load("message"))
    func messageFromEvent(_ fixture: Fixture) throws {
        let input = fixture.input
        let build = {
            try Message(
                server: input["server"] as! String, host: input["host"] as! String,
                selfID: input["self_id"] as! Int, event: input["event"] as! [String: Any]
            )
        }
        if fixture.error != nil {
            #expect(throws: MalformedEvent.self) { try build() }
            return
        }
        let expected = fixture.expected as! [String: Any]
        let message = try build()
        #expect(message == Message(fixture: expected["message"] as! [String: Any]))
        #expect(message.isMention == expected["is_mention"] as! Bool)
        #expect(message.isWildcardMention == expected["is_wildcard_mention"] as! Bool)
        #expect(message.hasAlertWord == expected["has_alert_word"] as! Bool)
    }
}

@Suite struct NarrowParity {
    @Test(arguments: Fixture.load("narrow"))
    func narrow(_ fixture: Fixture) {
        let expected = fixture.expected as! String
        if let text = fixture.input["text"] as? String {
            #expect(encodeComponent(text) == expected)
        } else {
            let message = Message(fixture: fixture.input["message"] as! [String: Any])
            #expect(narrowURL(message) == expected)
        }
    }
}

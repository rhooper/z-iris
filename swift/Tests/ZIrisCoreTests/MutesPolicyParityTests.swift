import Testing
import ZIrisCore

@Suite struct MutesParity {
    @Test(arguments: Fixture.load("mutes"))
    func mutes(_ fixture: Fixture) throws {
        let register = fixture.input["register"] as! [String: Any]
        if fixture.error != nil {
            #expect(throws: MalformedEvent.self) { try MuteState(register: register) }
            return
        }
        let queries = (fixture.input["queries"] as! [[Any]]).map { ($0[0] as! Int, $0[1] as! String) }
        var state = try MuteState(register: register)
        var answers = [queries.map { state.isMuted(channelID: $0.0, topic: $0.1) }]
        for event in fixture.input["events"] as! [[String: Any]] {
            try state.apply(event)
            answers.append(queries.map { state.isMuted(channelID: $0.0, topic: $0.1) })
        }
        #expect(answers == fixture.expected as! [[Bool]])
    }
}

@Suite struct PolicyParity {
    @Test(arguments: Fixture.load("policy"))
    func decide(_ fixture: Fixture) throws {
        let input = fixture.input
        let expected = fixture.expected as! [String: Any]
        let decision = ZIrisCore.decide(
            Message(fixture: input["message"] as! [String: Any]),
            mutes: try MuteState(register: input["register"] as! [String: Any]),
            selfID: input["self_id"] as! Int,
            notifyChannelMessages: input["notify_channel_messages"] as! Bool
        )
        #expect(decision == Decision(expected["notify"] as! Bool, expected["reason"] as! String))
    }
}

@Suite struct LowerParity {
    @Test(arguments: Fixture.load("lower"))
    func lower(_ fixture: Fixture) {
        #expect((fixture.input["text"] as! String).pythonLowercased == fixture.expected as! String)
    }
}

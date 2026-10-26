import Foundation
import Testing
@testable import ZIrisCore

@Suite struct PreviewParity {
    @Test(arguments: Fixture.load("preview"))
    func preview(_ fixture: Fixture) throws {
        let config = try parseConfig(fixture.input["toml"] as! String, sounds: fixtureSounds)
        let pipeline = Pipeline(server: "work", host: "chat.example.com", selfID: 5, mutes: MuteState(),
                                config: { config })
        let got = previewEntries(fixture.input["messages"] as! [[String: Any]], pipeline: pipeline)
        let want = fixture.expected as! [[String: Any]]
        #expect(got.count == want.count)
        for (entry, expected) in zip(got, want) {
            let plain: [String: Any] = [
                "id": entry.id, "sender": entry.sender, "where": entry.place, "text": entry.text,
                "why": entry.why, "rule_index": entry.ruleIndex as Any? ?? NSNull(), "notify": entry.notify,
                "sound": entry.sound as Any? ?? NSNull(), "volume": entry.volume as Any? ?? NSNull(),
            ]
            #expect(NSDictionary(dictionary: plain) == NSDictionary(dictionary: expected), "\(plain)\nwant \(expected)")
        }
    }
}

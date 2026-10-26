import Foundation
import Testing
@testable import ZIrisCore

@Suite struct BannerParity {
    @Test(arguments: Fixture.load("banner"))
    func banner(_ fixture: Fixture) {
        let input = fixture.input
        let note = ZIrisCore.Notification(
            message: Message(fixture: input["message"] as! [String: Any]), url: input["url"] as! String,
            reason: input["reason"] as! String, action: Action(fixture: input["action"] as! [String: Any]),
            summary: input["summary"] as? String
        )
        let want = fixture.expected as! [String: String]
        #expect(notificationTitle(note) == want["title"])
        #expect(plainBody(note.message) == want["plain_body"])
        #expect(bannerBody(note.message, limit: 80) == want["banner_body_80"])
        #expect(bannerGroup(note.message) == want["group"])
        #expect(dryRunText(note, player: ["play", "-q"]) + "\n" == want["dry_run"])
    }
}

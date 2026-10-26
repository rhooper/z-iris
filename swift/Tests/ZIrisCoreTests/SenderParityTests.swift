import Foundation
import Testing
import ZIrisCore

@Suite struct SenderParity {
    @Test(arguments: Fixture.load("sender"))
    func sender(_ fixture: Fixture) {
        let input = fixture.input
        let got: Sender?
        if let payload = input["json"] {
            got = Sender(json: payload)
        } else {
            got = senderFor(
                Message(fixture: input["message"] as! [String: Any]),
                title: input["title"] as! String,
                images: MessageImages(avatar: input["avatar"] as? String, picture: input["picture"] as? String)
            )
        }
        guard let expected = fixture.expected as? [String: Any] else {
            #expect(got == nil)
            return
        }
        #expect(got.map { NSDictionary(dictionary: $0.toJSON()) } == NSDictionary(dictionary: expected))
    }
}

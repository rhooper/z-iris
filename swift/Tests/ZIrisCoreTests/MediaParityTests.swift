import Foundation
import Testing
@testable import ZIrisCore

@Suite struct MediaParity {
    @Test(arguments: Fixture.load("media"))
    func media(_ fixture: Fixture) {
        let input = fixture.input
        switch input["op"] as! String {
        case "extract":
            #expect(extractImageURLs(input["content"] as! String) == fixture.expected as! [String])
        case "origin":
            let url = input["url"] as! String, base = input["base"] as! String
            let want = fixture.expected as! [String: Bool]
            #expect(sameOrigin(url, base) == want["same_origin"])
            #expect(credentialsAllowed(url, base: base) == want["credentials_allowed"])
            #expect(webOrRelative(url) == want["web_or_relative"])
        case "join":
            #expect(pyURLJoin(input["base"] as! String, input["url"] as! String) == fixture.expected as! String)
        default:
            Issue.record("unknown op")
        }
    }
}

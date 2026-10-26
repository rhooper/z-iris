import Testing
import ZIrisCore

@Suite struct TileParity {
    @Test(arguments: Fixture.load("tiles"))
    func tiles(_ fixture: Fixture) throws {
        let sender = try #require(Sender(json: fixture.input["sender"]!))
        let want = fixture.expected as! [String: Any]
        let tiles = groupTiles(sender)
        let plain = tiles.map { tile -> [String] in
            switch tile {
            case .avatar(let path): ["avatar", path]
            case let .initials(text, color): ["initials", text, color]
            }
        }
        #expect(plain == want["tiles"] as! [[String]])
        #expect(groupPictureName(tiles) == want["name"] as! String)
    }
}

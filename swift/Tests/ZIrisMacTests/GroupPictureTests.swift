import AppKit
import Testing
import ZIrisCore
@testable import ZIrisMac

@Suite struct GroupPictureTests {
    @Test func drawsOncePerSetOfTiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-groups-\(UUID().uuidString)")
        let sender = Sender(handle: "zulip:w:9", name: "Ada Lovelace", avatar: nil, picture: nil, conversation: "w:dm:3,9,12",
                            groupName: "group", members: [.init(handle: "zulip:w:3", name: "Bob"), .init(handle: "zulip:w:12", name: "Cy Twombly")])
        let path = try #require(groupPicture(sender, in: directory, size: 128))
        let image = NSImage(contentsOfFile: path)!
        #expect(image.representations.first?.pixelsWide == 128)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(groupPicture(sender, in: directory, size: 128) == path)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        #expect(URL(fileURLWithPath: path).lastPathComponent == groupPictureName(groupTiles(sender)))
    }
}

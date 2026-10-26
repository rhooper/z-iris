import Foundation
import Testing
@testable import ZIrisCore

@Suite struct URLStoreTests {
    private func store(limit: Int = 500) -> URLStore {
        URLStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-urls-\(UUID().uuidString)/urls.json"), limit: limit)
    }

    @Test func putPopDrop() {
        let urls = store()
        urls.put("a", "zulip://h/#a")
        urls.put("b", "zulip://h/#b")
        #expect(urls.pop("a") == "zulip://h/#a")
        #expect(urls.pop("a") == nil)
        urls.drop(["b", "missing"])
        #expect(urls.pop("b") == nil)
    }

    @Test func keepsTheNewestAndMovesARePutToTheEnd() {
        let urls = store(limit: 2)
        urls.put("a", "1")
        urls.put("b", "2")
        urls.put("a", "3")  // a is now newest
        urls.put("c", "4")  // so b goes
        #expect(urls.pop("b") == nil)
        #expect(urls.pop("a") == "3")
        #expect(urls.pop("c") == "4")
    }

    @Test func writesWhatPythonWrites() throws {
        let urls = store()
        urls.put("z-iris-work-1", "zulip://h/#narrow/é")
        urls.put("q\"uote", "back\\slash")
        let text = try String(contentsOf: urls.url, encoding: .utf8)
        let escaped = "\\u00e9"  // json.dump's ensure_ascii form of é
        #expect(text == "{\"z-iris-work-1\": \"zulip://h/#narrow/\(escaped)\", \"q\\\"uote\": \"back\\\\slash\"}")
    }

    @Test func readsInFileOrderAndIgnoresJunk() throws {
        let urls = store(limit: 2)
        try FileManager.default.createDirectory(at: urls.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"z": "1", "a": "2"}"#.write(to: urls.url, atomically: true, encoding: .utf8)
        urls.put("m", "3")  // z is oldest by file order, so it goes
        #expect(urls.pop("z") == nil)
        #expect(urls.pop("a") == "2")
        try "[1, 2]".write(to: urls.url, atomically: true, encoding: .utf8)
        #expect(urls.pop("a") == nil)
    }
}

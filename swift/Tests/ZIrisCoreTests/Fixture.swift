import Foundation
import Testing
import ZIrisCore

/// One case from a fixture file written by scripts/claude/gen_fixtures.py.
struct Fixture: CustomTestStringConvertible, Sendable {
    let name: String
    nonisolated(unsafe) let input: [String: Any]
    nonisolated(unsafe) let expected: Any?
    /// The Python exception's class name when the case is refused.
    let error: String?

    var testDescription: String { name }

    static func load(_ file: String) -> [Fixture] {
        guard let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { fatalError("missing fixture \(file).json; run scripts/claude/gen_fixtures.py") }
        return cases.map {
            Fixture(
                name: $0["name"] as! String,
                input: $0["input"] as! [String: Any],
                expected: $0["expected"],
                error: $0["error"] as? String
            )
        }
    }
}

extension Message {
    /// A message as gen_fixtures.py writes it (Python field names).
    init(fixture d: [String: Any]) {
        self.init(
            server: d["server"] as! String, host: d["host"] as! String, id: d["id"] as! Int,
            kind: Kind(rawValue: d["kind"] as! String)!, senderID: d["sender_id"] as! Int,
            senderName: d["sender_name"] as! String, content: d["content"] as! String,
            flags: Set(d["flags"] as! [String]), channelID: d["channel_id"] as? Int,
            channelName: d["channel_name"] as? String, topic: d["topic"] as? String,
            dmUserIDs: d["dm_user_ids"] as! [Int], avatarURL: d["avatar_url"] as? String,
            dmNames: d["dm_names"] as! [String]
        )
    }
}

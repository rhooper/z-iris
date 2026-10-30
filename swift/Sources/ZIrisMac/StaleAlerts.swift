import Foundation
import ZIrisCore
import ZulipKit

// A read event can be missed (the connection drops, or the read races the
// alert), so now and then each sticky alert's message is looked up, and the
// alerts for messages read or deleted since are cleared.

public struct StaleAlerts: Sendable {
    private let servers: @Sendable () -> [String]
    private let client: @Sendable (String) -> (any ZulipAPI)?
    private let delivered: @Sendable () async -> [String]?
    private let clear: @Sendable ([String]) async -> Void

    public init(
        servers: @escaping @Sendable () -> [String], client: @escaping @Sendable (String) -> (any ZulipAPI)?,
        delivered: @escaping @Sendable () async -> [String]?, clear: @escaping @Sendable ([String]) async -> Void
    ) {
        self.servers = servers
        self.client = client
        self.delivered = delivered
        self.clear = clear
    }

    /// Clear the alerts whose messages are read or gone; returns them.
    @discardableResult
    public func sweep() async -> [String] {
        guard let groups = await delivered() else { return [] }
        let names = servers()
        var stale: [String] = []
        for group in groups {
            guard let (server, id) = messageAlert(group, servers: names), let client = client(server) else { continue }
            guard let reply = try? await client.message(id) else { continue }  // unreachable: next time
            if reply.succeeded {
                let flags = (reply["message"] as? [String: Any])?["flags"] as? [String] ?? []
                if flags.contains("read") { stale.append(group) }
            } else if reply["code"] as? String == "BAD_REQUEST" {
                stale.append(group)  // deleted, or no longer visible
            }
        }
        if !stale.isEmpty {
            await clear(stale)
        }
        return stale
    }
}

/// The server and message of a single message's alert ("z-iris-<server>-<id>");
/// nil for summaries and anything else.
func messageAlert(_ group: String, servers: [String]) -> (String, Int)? {
    for server in servers {
        let prefix = "z-iris-\(server)-"
        guard group.hasPrefix(prefix) else { continue }
        let digits = group.dropFirst(prefix.count)
        if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(digits) {
            return (server, id)
        }
    }
    return nil
}

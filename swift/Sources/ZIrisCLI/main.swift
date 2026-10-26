import Foundation
import ZIrisCore
import ZulipKit

// z-iris's command line while the Swift port is under way. `probe` registers
// with each configured server, reports what came back, and deregisters. It
// reads nothing else and never prints the zuliprc.

let configPath = ("~/.config/z-iris/config.toml" as NSString).expandingTildeInPath

/// The bundled tones: the app's resources later; the repository for now.
func builtinSounds() -> URL {
    if let path = ProcessInfo.processInfo.environment["Z_IRIS_SOUNDS"] {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../src/z_iris/sounds").standardized
}

func probe() async -> Int32 {
    let config: Config
    do {
        let sounds = soundLibrary(
            builtin: builtinSounds(),
            user: URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("sounds")
        )
        config = try loadConfig(at: configPath, sounds: sounds)
    } catch {
        print("z-iris: \(error)")
        return 1
    }
    for server in config.servers {
        do {
            let client = try ZulipClient(zuliprc: server.zuliprc)
            let reply = try await client.register(
                eventTypes: ["message", "subscription", "user_topic", "muted_topics"],
                applyMarkdown: false, clientGravatar: false
            )
            print("\(server.name): result=\(reply["result"] ?? "None") base_url=\(client.credentials.baseURL.absoluteString)")
            if reply.succeeded {
                print("  keys:", reply.value.keys.sorted(by: pythonOrder).joined(separator: ", "))
                for key in ["subscriptions", "user_topics", "muted_topics"] {
                    if let list = reply[key] as? [Any] {
                        print("  \(key): \(list.count)")
                    }
                }
                if let queue = reply["queue_id"] as? String {
                    _ = try await client.deregister(queueID: queue)
                }
            } else {
                print("  error:", reply["msg"] ?? "None")
            }
        } catch {
            print("\(server.name): \(error)")
        }
    }
    return 0
}

switch CommandLine.arguments.dropFirst().first {
case "probe":
    exit(await probe())
default:
    print("usage: z-iris-cli probe")
    exit(2)
}

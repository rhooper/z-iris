import Foundation
import ZIrisCore
import ZulipKit
import ZIrisMac
import AppKit
import AVFoundation

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

/// z-iris-cli flash <mode> [color] [seconds]: one test flash, as `z-iris flash`.
@MainActor
func flash(_ arguments: [String]) -> Int32 {
    let modes = ["screen", "top", "bottom", "left", "right"]
    guard let mode = arguments.first, modes.contains(mode) else {
        print("usage: z-iris-cli flash \(modes.joined(separator: "|")) [#rrggbb] [seconds]")
        return 2
    }
    let color = arguments.count > 1 ? arguments[1] : fallbackColor
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 0.6 : 0.6
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let flasher = Flasher()
    flasher.show(mode: mode, color: color, seconds: seconds)
    Timer.scheduledTimer(withTimeInterval: seconds + 0.3, repeats: false) { _ in exit(0) }
    app.run()
    return 0
}

/// z-iris-cli play FILE [volume] [device]: one sound through SoundPlayer.
func play(_ arguments: [String]) async -> Int32 {
    guard let path = arguments.first else {
        print("usage: z-iris-cli play FILE [volume] [device]")
        return 2
    }
    let player = SoundPlayer(device: arguments.count > 2 ? arguments[2...].joined(separator: " ") : nil)
    player.play(path, volume: arguments.count > 1 ? Int(arguments[1]) ?? 100 : 100)
    let seconds = (try? AVAudioFile(forReading: URL(fileURLWithPath: path))).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 1
    try? await Task.sleep(for: .seconds(seconds + 0.5))
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "probe":
    exit(await probe())
case "play":
    exit(await play(Array(arguments.dropFirst())))
case "flash":
    exit(await MainActor.run { flash(Array(arguments.dropFirst())) })
default:
    print("usage: z-iris-cli probe | flash <mode> [#rrggbb] [seconds] | play FILE [volume] [device]")
    exit(2)
}

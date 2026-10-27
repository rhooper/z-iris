import AppKit
import AVFoundation
import Foundation
import ZIrisCore
import ZIrisMac
import ZulipKit

// z-iris: the menubar app, or a command (__main__.py).
//   z-iris [--config PATH] [--dry-run | --headless]
//   z-iris probe | edit | normalize [--dir DIR] [--no-backup]
//   z-iris flash MODE [#rrggbb] [seconds] | play FILE [volume] [device]

let defaultConfigPath = ("~/.config/z-iris/config.toml" as NSString).expandingTildeInPath
let bannerURLs = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/z-iris/banner-urls.json")

/// True when running as an app bundle (not `swift run`).
let inBundle = Bundle.main.bundlePath.hasSuffix(".app")

/// A resource: the bundle's in the app, swift/Resources's in development.
func resource(_ name: String) -> URL {
    if inBundle, let path = Bundle.main.resourcePath {
        return URL(fileURLWithPath: path).appendingPathComponent(name)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/" + name).standardized
}

struct Options {
    var config = defaultConfigPath
    var dryRun = false
    var headless = false
    var directory: String?
    var backup = true
    var command: String?
    var rest: [String] = []
}

func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--config":
            guard index + 1 < arguments.count else { return nil }
            options.config = (arguments[index + 1] as NSString).expandingTildeInPath
            index += 1
        case "--dry-run": options.dryRun = true
        case "--headless": options.headless = true
        case "--dir":
            guard index + 1 < arguments.count else { return nil }
            options.directory = arguments[index + 1]
            index += 1
        case "--no-backup": options.backup = false
        case "probe", "normalize", "edit":
            guard options.command == nil else { return nil }
            options.command = argument
        case "flash", "play":
            guard options.command == nil else { return nil }
            options.command = argument
            options.rest = Array(arguments[(index + 1)...])
            return options
        default:
            return nil
        }
        index += 1
    }
    return options
}

func soundLibrary(for configPath: String) -> [String: String] {
    soundLibrary(
        builtin: resource("sounds"),
        user: URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("sounds")
    )
}

func probe(_ config: Config) async -> Int32 {
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
                    if let list = reply[key] as? [Any] { print("  \(key): \(list.count)") }
                }
                if let queue = reply["queue_id"] as? String { _ = try await client.deregister(queueID: queue) }
            } else {
                print("  error:", reply["msg"] ?? "None")
            }
        } catch {
            print("\(server.name): \(error)")
        }
    }
    return 0
}

@MainActor
func flash(_ arguments: [String]) -> Int32 {
    let modes = ["screen", "top", "bottom", "left", "right"]
    guard let mode = arguments.first, modes.contains(mode) else {
        print("usage: z-iris flash \(modes.joined(separator: "|")) [#rrggbb] [seconds]")
        return 2
    }
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 0.6 : 0.6
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Flasher().show(mode: mode, color: arguments.count > 1 ? arguments[1] : fallbackColor, seconds: seconds)
    Timer.scheduledTimer(withTimeInterval: seconds + 0.3, repeats: false) { _ in exit(0) }
    app.run()
    return 0
}

func play(_ arguments: [String]) async -> Int32 {
    guard let path = arguments.first else {
        print("usage: z-iris play FILE [volume] [device]")
        return 2
    }
    let player = SoundPlayer(device: arguments.count > 2 ? arguments[2...].joined(separator: " ") : nil)
    player.play(path, volume: arguments.count > 1 ? Int(arguments[1]) ?? 100 : 100)
    let seconds = (try? AVAudioFile(forReading: URL(fileURLWithPath: path))).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 1
    try? await Task.sleep(for: .seconds(seconds + 0.5))
    return 0
}

/// Server name to its current client, for the image fetcher.
final class Clients: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: any ZulipAPI] = [:]

    func set(_ server: String, _ client: any ZulipAPI) { lock.withLock { clients[server] = client } }
    func get(_ server: String) -> (any ZulipAPI)? { lock.withLock { clients[server] } }
}

@MainActor
func run(_ options: Options, _ config: Config) -> Int32 {
    let configPath = options.config
    let settings = Settings(config, path: configPath, sounds: { soundLibrary(for: configPath) })
    let pause = PauseFlag()
    let clients = Clients()
    let output: any EngineOutput
    if options.dryRun {
        output = DryRunOutput(player: config.player)
    } else {
        // A clicked banner clears its thread in z-iris priority too; the link
        // needs the banners as its fallback, so it is filled in after.
        final class LinkBox: @unchecked Sendable { var link: PriorityLink? }  // set once, before any click
        let box = LinkBox()
        let banners = BannerNotifier(urls: URLStore(url: bannerURLs), clickedThread: { box.link?.clearThread($0) })
        let resolver = ImageResolver(clients: { clients.get($0) }, externalImages: { settings.config.externalImages })
        // Sticky alerts come from z-iris-priority.app; it falls back to our banners.
        box.link = inBundle ? PriorityLink(fallback: banners) : nil
        output = RealOutput(
            config: { settings.config }, notifier: banners,
            priority: box.link,
            images: { await resolver.images(for: $0) }, player: SoundPlayer(),
            flasher: options.headless ? nil : Flasher(),
            // Only used for rules with summarize = true; quiet when the model is unavailable.
            summarizer: ModelSummarizer()
        )
    }
    var log: (@Sendable (String) -> Void)?
    if options.dryRun {
        log = { print("[dry-run] engine \($0)") }
    }
    let engine = Engine(output: output, config: { settings.config }, isPaused: { pause.isPaused }, log: log)
    let editor = EditorWindow {
        EditorModel(configPath: configPath, settings: settings,
                    builtinSounds: resource("sounds"),
                    player: SoundPlayer(), flasher: Flasher())
    }
    let menu = (options.dryRun || options.headless) ? nil
        : MenuBar(settings: settings, pause: pause,
                  icon: resource("z-iris-menubarTemplate.png").path,
                  editRules: { editor.show() })
    let conversations = Conversations(file: Conversations.defaultFile, hours: { settings.config.joinedHours })
    for server in config.servers {
        let stream = EventStream(
            server: server.name, makeClient: { try ZulipClient(zuliprc: server.zuliprc) }, sink: engine,
            config: { settings.config },
            status: { text in Task { @MainActor in menu?.status(server.name, text) } },
            onClient: { clients.set(server.name, $0) }, conversations: conversations
        )
        Task.detached { await stream.run() }
    }
    if menu == nil {
        // Headless: watch the config and report its problems once each.
        final class Last: @unchecked Sendable { var error: String? }  // only the main run loop's timer uses it
        let last = Last()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let error = settings.reload()
            if let error, error != last.error {
                FileHandle.standardError.write(Data("z-iris: config: \(error)\n".utf8))
            }
            last.error = error
        }
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
        return 0
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(menu) { app.run() }
    return 0
}

// Line by line, as Python's print(flush=True): dry runs are read as they happen.
setvbuf(stdout, nil, _IOLBF, 0)

/// Run an async command and exit with its status. The top level stays
/// synchronous: with a top-level await, main.swift becomes an async main whose
/// app.run() sits inside one main-queue job, and nothing else queued to the
/// main actor or main queue (menu updates, flashes, clicks) would ever run.
func command(_ work: @escaping @Sendable () async -> Int32) -> Never {
    Task { exit(await work()) }
    dispatchMain()
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    print("usage: z-iris [--config PATH] [--dry-run | --headless] | probe | edit | normalize [--dir DIR] [--no-backup] | flash MODE [#rrggbb] [seconds] | play FILE [volume] [device]")
    exit(2)
}
switch options.command {
case "flash":
    exit(flash(options.rest))
case "play":
    let rest = options.rest
    command { await play(rest) }
case "normalize":
    let directory = options.directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: options.config).deletingLastPathComponent().appendingPathComponent("sounds")
    let changed = normalizeDirectory(directory, keepOriginals: options.backup)
    for (before, after) in changed {
        print("normalized \(before.lastPathComponent) -> \(after.lastPathComponent)")
    }
    print("\(changed.count) changed in \(directory.path)")
    exit(0)
default:
    break
}
let config: Config
do {
    config = try loadConfig(at: options.config, sounds: soundLibrary(for: options.config))
} catch {
    FileHandle.standardError.write(Data("z-iris: \(error)\n".utf8))
    exit(2)
}
if options.command == "probe" {
    command { await probe(config) }
}
if options.command == "edit" {
    // The editor alone, as `z-iris edit` opened the web editor; quits with its window.
    let settings = Settings(config, path: options.config, sounds: { soundLibrary(for: options.config) })
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let editor = EditorWindow {
        EditorModel(configPath: options.config, settings: settings,
                    builtinSounds: resource("sounds"), player: SoundPlayer(), flasher: Flasher())
    }
    editor.show()
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in exit(0) }
    app.run()
}
exit(run(options, config))

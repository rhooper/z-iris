import Foundation
import TOMLDecoder

// Load z-iris settings from a TOML file. Checks run in the Python version's
// order with its messages, so the same config fails the same way.

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var description: String

    init(_ description: String) {
        self.description = description
    }
}

public enum BehaviourValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case integer(Int)
    case flag(Bool)
}

public typealias Behaviour = [String: BehaviourValue]

private struct BehaviourSetting: Sendable {
    var key: String
    var check: @Sendable (Any, String) throws(ConfigError) -> BehaviourValue
    var builtIn: BehaviourValue
}

/// Settings a rule may override and [defaults] may set, with built-in values.
private let behaviourSettings: [BehaviourSetting] = [
    BehaviourSetting(key: "flash", check: choice("none", "screen", "top", "bottom", "left", "right"), builtIn: .text("none")),
    BehaviourSetting(key: "flash_color", check: color, builtIn: .text("#ff3b30")),
    BehaviourSetting(key: "flash_seconds", check: number("0.1", "10"), builtIn: .number(0.6)),
    BehaviourSetting(key: "repeat", check: integer(0, 20), builtIn: .integer(0)),
    BehaviourSetting(key: "repeat_every", check: integer(1, 3600), builtIn: .integer(30)),
    BehaviourSetting(key: "repeat_boost", check: integer(0, 100), builtIn: .integer(0)),
    BehaviourSetting(key: "min_gap", check: integer(0, 3600), builtIn: .integer(0)),
    BehaviourSetting(key: "batch_window", check: integer(0, 300), builtIn: .integer(0)),
    BehaviourSetting(key: "sticky", check: { value, label throws(ConfigError) in .flag(try bool(value, label)) }, builtIn: .flag(false)),
    // Seconds on screen; 0 is a normal banner.
    BehaviourSetting(key: "stay", check: integer(0, 3600), builtIn: .integer(0)),
    // A batch summary's text from the on-device model (new in the Swift version).
    BehaviourSetting(key: "summarize", check: { value, label throws(ConfigError) in .flag(try bool(value, label)) }, builtIn: .flag(false)),
]

/// An int the way Python's isinstance(value, int) sees TOML values: bool is not one.
private func pyInt(_ value: Any?) -> Int? {
    switch value {
    case let number as Int64: Int(number)
    case let number as Int: number
    default: nil
    }
}

private func integer(_ low: Int, _ high: Int) -> @Sendable (Any, String) throws(ConfigError) -> BehaviourValue {
    { value, label throws(ConfigError) in
        guard let number = pyInt(value) else {
            throw ConfigError("\(label) must be an integer from \(low) to \(high)")
        }
        guard low <= number, number <= high else {
            throw ConfigError("\(label) must be from \(low) to \(high)")
        }
        return .integer(number)
    }
}

private func number(_ low: String, _ high: String) -> @Sendable (Any, String) throws(ConfigError) -> BehaviourValue {
    { value, label throws(ConfigError) in
        let number: Double
        switch value {
        case let double as Double: number = double
        default:
            guard let int = pyInt(value) else {
                throw ConfigError("\(label) must be a number from \(low) to \(high)")
            }
            number = Double(int)
        }
        guard Double(low)! <= number, number <= Double(high)! else {
            throw ConfigError("\(label) must be from \(low) to \(high)")
        }
        return .number(number)
    }
}

private func choice(_ choices: String...) -> @Sendable (Any, String) throws(ConfigError) -> BehaviourValue {
    { value, label throws(ConfigError) in
        guard let text = value as? String, choices.contains(text) else {
            throw ConfigError("\(label) must be one of \(choices.joined(separator: ", "))")
        }
        return .text(text)
    }
}

private func bool(_ value: Any?, _ label: String) throws(ConfigError) -> Bool {
    guard let flag = value as? Bool else { throw ConfigError("\(label) must be true or false") }
    return flag
}

private func color(_ value: Any, _ label: String) throws(ConfigError) -> BehaviourValue {
    guard let text = value as? String, text.count == 7, text.first == "#",
          text.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
    else { throw ConfigError("\(label) must be a colour like #ff3b30") }
    return .text(text.lowercased())
}

private func behaviour(_ raw: [String: Any], _ label: String) throws(ConfigError) -> Behaviour {
    var found: Behaviour = [:]
    for setting in behaviourSettings {
        if let value = raw[setting.key] {
            found[setting.key] = try setting.check(value, label.isEmpty ? setting.key : "\(label): \(setting.key)")
        }
    }
    return found
}

public struct FocusConfig: Sendable, Equatable {
    /// off, mentions_and_dms, or silent.
    public var mode = "off"
    /// (start, end) minutes after midnight.
    public var quietHours: [QuietHours] = []
    /// What quiet hours do: mentions_and_dms or silent.
    public var quietMode = "silent"

    public struct QuietHours: Sendable, Equatable {
        public var start: Int
        public var end: Int
    }

    public init() {}
}

private func focus(_ data: [String: Any]) throws(ConfigError) -> FocusConfig {
    let table = try table(data, "focus")
    let modes = ["off", "mentions_and_dms", "silent"]
    var focus = FocusConfig()
    let mode = table["mode"] ?? "off"
    guard let mode = mode as? String, modes.contains(mode) else {
        throw ConfigError("focus: mode must be one of \(modes.joined(separator: ", "))")
    }
    let quietMode = table["quiet_mode"] ?? "silent"
    guard let quietMode = quietMode as? String, modes.dropFirst().contains(quietMode) else {
        throw ConfigError("focus: quiet_mode must be one of \(modes.dropFirst().joined(separator: ", "))")
    }
    guard let rawHours = (table["quiet_hours"] ?? [Any]()) as? [Any] else {
        throw ConfigError("focus: quiet_hours must be a list like [\"22:00-07:00\"]")
    }
    for entry in rawHours {
        guard let text = entry as? String, let parts = clockRange(text) else {
            throw ConfigError("focus: bad quiet hours \(pythonRepr(entry)), use HH:MM-HH:MM")
        }
        let (a, b, c, d) = parts
        guard a < 24, c < 24, b < 60, d < 60 else {
            throw ConfigError("focus: bad time in quiet hours \(pythonRepr(entry))")
        }
        if (a, b) == (c, d) {
            throw ConfigError(
                "focus: quiet hours \(pythonRepr(entry)) start and end together, so it would "
                    + "never be quiet; use 00:00-23:59 for all day"
            )
        }
        focus.quietHours.append(.init(start: a * 60 + b, end: c * 60 + d))
    }
    focus.mode = mode
    focus.quietMode = quietMode
    return focus
}

/// HH:MM-HH:MM with one or two hour digits, as Python's \d reads them.
private func clockRange(_ text: String) -> (Int, Int, Int, Int)? {
    let halves = text.split(separator: "-", omittingEmptySubsequences: false)
    guard halves.count == 2 else { return nil }
    var numbers: [Int] = []
    for half in halves {
        let parts = half.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2 else { return nil }
        for part in parts {
            var value = 0
            for char in part {
                guard char.isNumber, let digit = char.wholeNumberValue,
                      char.unicodeScalars.first!.properties.numericType == .decimal
                else { return nil }
                value = value * 10 + digit
            }
            numbers.append(value)
        }
    }
    return (numbers[0], numbers[1], numbers[2], numbers[3])
}

public struct ServerConfig: Sendable, Equatable {
    public var name: String
    public var zuliprc: String
    public var volume = 100

    public init(name: String, zuliprc: String, volume: Int = 100) {
        self.name = name
        self.zuliprc = zuliprc
        self.volume = volume
    }
}

public struct Config: Sendable, Equatable {
    public var servers: [ServerConfig]
    public var sound = "chime"
    public var volume = 60
    public var notifyChannelMessages = false
    public var player = ["play", "-q"]
    public var notifier = "terminal-notifier"
    public var externalImages = false
    public var masterVolume = 100
    public var rules: [Rule] = []
    /// [defaults] overrides of the behaviour settings.
    public var behaviour: Behaviour = [:]
    public var focus = FocusConfig()
    /// Sound names to files.
    public var sounds: [String: String] = [:]
}

public struct Action: Sendable, Equatable {
    public var sound: String
    public var volume: Int
    public var banner: String
    /// The rule's label, for people.
    public var rule: String?
    public var flash = "none"
    public var flashColor = "#ff3b30"
    public var flashSeconds = 0.6
    public var `repeat` = 0
    public var repeatEvery = 30
    public var repeatBoost = 0
    public var minGap = 0
    public var batchWindow = 0
    public var sticky = false
    /// Seconds a persistent alert stays; 0 is a normal banner.
    public var stay = 0
    /// Replace a batch summary's text with one written by the on-device model.
    public var summarize = false
    /// Which rule, for per-rule state (labels can repeat).
    public var ruleIndex: Int?

    public init(sound: String, volume: Int, banner: String, rule: String?, ruleIndex: Int? = nil) {
        self.sound = sound
        self.volume = volume
        self.banner = banner
        self.rule = rule
        self.ruleIndex = ruleIndex
    }
}

/// Combine a rule with the defaults. Volume is rule x server x master.
public func resolveAction(_ config: Config, server: String, rule: Rule?) -> Action {
    let serverVolume = config.servers.first { $0.name == server }?.volume ?? 100
    let base = rule?.volume ?? config.volume
    var sound = rule?.sound ?? config.sound
    let banner = rule?.banner ?? "full"
    // Python's round() rounds halves to even.
    let final = Int((Double(base * serverVolume * config.masterVolume) / 10000).rounded(.toNearestOrEven))
    if let path = config.sounds[sound] {
        sound = path
    }
    var merged: Behaviour = [:]
    for setting in behaviourSettings {
        merged[setting.key] = setting.builtIn
    }
    merged.merge(config.behaviour) { $1 }
    if let rule {
        merged.merge(rule.behaviour) { $1 }
    }
    var action = Action(sound: sound, volume: final, banner: banner, rule: rule?.label, ruleIndex: rule?.index)
    for (key, value) in merged {
        switch (key, value) {
        case ("flash", .text(let text)): action.flash = text
        case ("flash_color", .text(let text)): action.flashColor = text
        case ("flash_seconds", .number(let number)): action.flashSeconds = number
        case ("repeat", .integer(let number)): action.repeat = number
        case ("repeat_every", .integer(let number)): action.repeatEvery = number
        case ("repeat_boost", .integer(let number)): action.repeatBoost = number
        case ("min_gap", .integer(let number)): action.minGap = number
        case ("batch_window", .integer(let number)): action.batchWindow = number
        case ("sticky", .flag(let flag)): action.sticky = flag
        case ("stay", .integer(let number)): action.stay = number
        case ("summarize", .flag(let flag)): action.summarize = flag
        default: assertionFailure("behaviour \(key) has the wrong type")
        }
    }
    return action
}

/// Path(value) as text, empty and "." parts dropped; with expandUser,
/// Path(value).expanduser().
func pythonPath(_ value: String, expandUser: Bool = true) -> String {
    let expanded = expandUser ? (value as NSString).expandingTildeInPath : value
    let absolute = expanded.hasPrefix("/")
    let parts = expanded.split(separator: "/").filter { $0 != "." }
    let joined = parts.joined(separator: "/")
    if absolute { return "/" + joined }
    return joined.isEmpty ? "." : joined
}

/// A sound is "none", a library name, or (older configs) a file path.
private func sound(_ value: Any?, _ label: String, _ sounds: [String: String]) throws(ConfigError) -> String {
    guard let text = value as? String, !text.isEmpty else {
        throw ConfigError("\(label) must be a sound name, a file path or 'none'")
    }
    if text == "none" || sounds[text] != nil {
        return text
    }
    let path = pythonPath(text)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
        return path
    }
    let choices = sounds.keys.sorted(by: pythonOrder).joined(separator: ", ")
    throw ConfigError("\(label): unknown sound \(pythonRepr(text)); choose none or one of \(choices)")
}

/// Python sorts strings by code point; Swift's < compares grapheme clusters.
public func pythonOrder(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

private func percent(_ value: Any?, _ label: String) throws(ConfigError) -> Int {
    guard let number = pyInt(value), (0...100).contains(number) else {
        throw ConfigError("\(label) must be an integer from 0 to 100")
    }
    return number
}

private func tables(_ data: [String: Any], _ key: String) throws(ConfigError) -> [[String: Any]] {
    guard let list = (data[key] ?? [Any]()) as? [Any],
          let tables = list as? [[String: Any]], tables.count == list.count
    else { throw ConfigError("[[\(key)]] must be a list of tables, written [[\(key)]]") }
    return tables
}

private func table(_ data: [String: Any], _ key: String) throws(ConfigError) -> [String: Any] {
    guard let table = (data[key] ?? [String: Any]()) as? [String: Any] else {
        throw ConfigError("[\(key)] must be a table")
    }
    return table
}

private func rules(
    _ data: [String: Any], serverNames: Set<String>, sounds: [String: String]
) throws(ConfigError) -> [Rule] {
    var rules: [Rule] = []
    for (index, raw) in try tables(data, "rule").enumerated() {
        // An optional description; older configs called it name.
        let rawDescription = raw.keys.contains("description") ? raw["description"] : raw["name"]
        if let rawDescription, !(rawDescription is String) {
            throw ConfigError("rule number \(index + 1): description must be text")
        }
        let description = (rawDescription as? String).flatMap { $0.isEmpty ? nil : $0 }
        let label = description.map { "rule \(pythonRepr($0))" } ?? "rule number \(index + 1)"
        guard let kindName = raw["match"] as? String, let kind = RuleKind(rawValue: kindName) else {
            throw ConfigError("\(label): match must be one of \(RuleKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        // One channel or a list; each a pattern for the whole channel name.
        var channels: [String]?
        switch raw["channel"] {
        case nil: channels = nil
        case let one as String: channels = [one]
        case let list as [Any]:
            let names = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard !list.isEmpty, names.count == list.count else { fallthrough }
            channels = names
        default:
            throw ConfigError("\(label): channel must be a channel name or a list of them")
        }
        if channels?.contains("") == true {
            throw ConfigError("\(label): channel must be a channel name or a list of them")
        }
        if channels != nil, kind != .channel, kind != .topic {
            throw ConfigError("\(label): channel only applies to channel and topic rules")
        }
        if kind == .channel, channels == nil {
            throw ConfigError("\(label): a channel rule needs channel")
        }
        for source in channels ?? [] {
            do {
                _ = try PyRegex(source)
            } catch {
                throw ConfigError("\(label): bad channel pattern \(pythonRepr(source)): \(error)")
            }
        }

        var pattern: PyRegex?
        if kind == .topic || kind == .keyword {
            guard let source = raw[kind.rawValue] as? String, !source.isEmpty else {
                throw ConfigError("\(label): a \(kind.rawValue) rule needs \(kind.rawValue)")
            }
            do {
                pattern = try PyRegex(source)
            } catch {
                throw ConfigError("\(label): bad regular expression: \(error)")
            }
        }

        let server = raw["server"]
        if let server, !((server as? String).map(serverNames.contains) ?? false) {
            throw ConfigError("\(label): unknown server \(pythonRepr(server))")
        }

        let volume = try raw["volume"].map { value throws(ConfigError) in try percent(value, "\(label): volume") }

        let banner = raw["banner"]
        if let banner, !["full", "title", "off"].contains(banner as? String ?? "") {
            throw ConfigError("\(label): banner must be full, title or off")
        }

        let sound = try raw["sound"].map { value throws(ConfigError) in try sound(value, label, sounds) }

        guard let enabled = (raw["enabled"] ?? true) as? Bool else {
            throw ConfigError("\(label): enabled must be true or false")
        }

        guard let priority = pyInt(raw["priority"] ?? Int64(0)) else {
            throw ConfigError("\(label): priority must be an integer")
        }

        let found = try behaviour(raw, label)
        do {
            rules.append(try Rule(
                description: description, kind: kind, channels: channels ?? [], pattern: pattern,
                server: server as? String, sound: sound, volume: volume, banner: banner as? String,
                priority: priority, index: index, enabled: enabled, behaviour: found
            ))
        } catch {
            throw ConfigError("\(label): bad channel pattern: \(error)")
        }
    }
    return rules
}

private func servers(_ data: [String: Any]) throws(ConfigError) -> [ServerConfig] {
    let rawServers = try tables(data, "server")
    if rawServers.isEmpty {
        throw ConfigError("at least one [[server]] is required")
    }
    var servers: [ServerConfig] = []
    var seen: Set<String> = []
    for raw in rawServers {
        guard let name = raw["name"] as? String, !name.isEmpty else {
            throw ConfigError("each [[server]] needs a name")
        }
        guard let zuliprc = raw["zuliprc"] as? String, !zuliprc.isEmpty else {
            throw ConfigError("server \(pythonRepr(name)) needs a zuliprc path")
        }
        if seen.contains(name) {
            throw ConfigError("duplicate server name \(pythonRepr(name))")
        }
        seen.insert(name)
        let volume = try percent(raw["volume"] ?? Int64(100), "server \(pythonRepr(name)) volume")
        servers.append(ServerConfig(name: name, zuliprc: pythonPath(zuliprc), volume: volume))
    }
    return servers
}

/// Parse config text. `sounds` is the sound library (name to file).
public func parseConfig(_ text: String, sounds: [String: String]) throws(ConfigError) -> Config {
    // TOMLDecoder 0.4.5 force-unwraps withContiguousStorageIfAvailable, so a
    // bridged NSString (from a file or JSON) would crash it.
    var text = text
    text.makeContiguousUTF8()
    let data: [String: Any]
    do {
        data = try [String: Any](TOMLTable(source: text))
    } catch {
        throw ConfigError("invalid TOML: \(error)")
    }

    var config = Config(servers: try servers(data))
    config.sounds = sounds
    let defaults = try table(data, "defaults")
    let output = try table(data, "output")

    config.volume = try percent(defaults["volume"] ?? Int64(60), "volume")
    config.masterVolume = try percent(defaults["master_volume"] ?? Int64(100), "master_volume")
    config.sound = try sound(defaults["sound"] ?? "chime", "default sound", sounds)

    guard let notify = (defaults["notify_channel_messages"] ?? false) as? Bool else {
        throw ConfigError("notify_channel_messages must be true or false")
    }
    config.notifyChannelMessages = notify

    let player = (output["player"] ?? ["play", "-q"]) as? [Any] ?? []
    guard !player.isEmpty, let parts = player as? [String], parts.count == player.count else {
        throw ConfigError("player must be a non-empty list of strings")
    }
    config.player = parts

    guard let notifier = (output["notifier"] ?? "terminal-notifier") as? String, !notifier.isEmpty else {
        throw ConfigError("notifier must be a command name or path")
    }
    config.notifier = notifier

    guard let externalImages = (output["external_images"] ?? false) as? Bool else {
        throw ConfigError("external_images must be true or false")
    }
    config.externalImages = externalImages

    config.rules = try rules(data, serverNames: Set(config.servers.map(\.name)), sounds: sounds)
    config.behaviour = try behaviour(defaults, "")
    config.focus = try focus(data)
    return config
}

public func loadConfig(at path: String, sounds: [String: String]) throws(ConfigError) -> Config {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw ConfigError("no config at \(path); copy config.example.toml there and edit it")
    }
    return try parseConfig(text, sounds: sounds)
}

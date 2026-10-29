import Foundation
import TOMLDecoder

// Edit the config file's rules and volumes while keeping its comments. The
// output is byte for byte what editing.py (tomlkit) writes.

/// "reaction" is the rule's [rule.reaction] sub-table and "except" its
/// [[rule.except]] tables, written after it in that order.
public let ruleFields = [
    "description", "match", "channel", "sender", "with", "topic", "keyword", "emoji", "server", "sound",
    "volume", "banner", "priority", "enabled", "join", "flash", "flash_color",
    "flash_seconds", "repeat", "repeat_every", "repeat_boost", "min_gap",
    "batch_window", "sticky", "stay", "summarize", "group_after", "reaction", "except",
]
public let focusFields = ["mode", "quiet_hours", "quiet_mode"]
public let defaultFields = [
    "sound", "volume", "master_volume", "notify_channel_messages", "flash",
    "flash_color", "flash_seconds", "repeat", "repeat_every", "repeat_boost",
    "min_gap", "batch_window", "sticky", "stay", "summarize", "join_on_mention",
    "joined_hours", "reactions", "group_after",
]

/// What the editor may change. Absent parts are left alone.
public struct EditPayload: Sendable {
    public var defaults: [String: TOMLValue]?
    public var focus: [String: TOMLValue]?
    public var servers: [(name: String, volume: TOMLValue?)] = []
    /// Each rule's fields; "name" is read as an older description.
    public var rules: [[String: TOMLValue]]?

    public init(defaults: [String: TOMLValue]? = nil, focus: [String: TOMLValue]? = nil,
                servers: [(name: String, volume: TOMLValue?)] = [], rules: [[String: TOMLValue]]? = nil) {
        self.defaults = defaults
        self.focus = focus
        self.servers = servers
        self.rules = rules
    }
}

extension EditPayload {
    /// The editor's whole state, as it sends it on every save.
    public init(state editable: EditableConfig) {
        self.init(defaults: editable.defaults, focus: editable.focus,
                  servers: editable.servers.map { ($0, nil) }, rules: editable.rules)
    }
}

/// The parts of the config the editor may show. Never includes zuliprc paths.
public struct EditableConfig: Sendable, Equatable {
    public var servers: [String]
    public var defaults: [String: TOMLValue]
    public var focus: [String: TOMLValue]
    public var rules: [[String: TOMLValue]]

    public init(servers: [String], defaults: [String: TOMLValue], focus: [String: TOMLValue], rules: [[String: TOMLValue]]) {
        self.servers = servers
        self.defaults = defaults
        self.focus = focus
        self.rules = rules
    }
}

private func document(_ text: String) throws(EditingError) -> [String: Any] {
    var text = text
    text.makeContiguousUTF8()  // see parseConfig
    do {
        return try [String: Any](TOMLTable(source: text))
    } catch {
        throw EditingError(description: "invalid TOML: \(error)")
    }
}

/// A decoded TOML value as a TOMLValue; dates become their text.
func tomlValue(_ value: Any) -> TOMLValue {
    switch value {
    case let flag as Bool: .bool(flag)
    case let number as Int64: .integer(Int(number))
    case let number as Int: .integer(number)
    case let number as Double: .float(number)
    case let text as String: .string(text)
    case let list as [Any]: .array(list.map(tomlValue))
    case let table as [String: Any]: .table(ruleFields.compactMap { key in table[key].map { (key, tomlValue($0)) } })
    default: .string(String(describing: value))
    }
}

private extension TOMLValue {
    /// Python truthiness, for `or` defaults.
    var truthy: Bool {
        switch self {
        case .string(let text): !text.isEmpty
        case .integer(let number): number != 0
        case .float(let number): number != 0
        case .bool(let flag): flag
        case .array(let items): !items.isEmpty
        case .table(let keys): !keys.isEmpty
        }
    }

    var number: Double? {
        switch self {
        case .integer(let number): Double(number)
        case .float(let number): number
        case .bool(let flag): flag ? 1 : 0
        default: nil
        }
    }
}

private func tables(_ data: [String: Any], _ key: String) -> [[String: Any]] {
    (data[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
}

/// The one volume every server has, if they agree; folded into the master so
/// the editor shows just a rule's volume and the master.
private func sharedServerVolume(_ servers: [[String: Any]]) -> TOMLValue? {
    let volumes = servers.map { $0["volume"].map(tomlValue) ?? .integer(100) }
    // Python's set {50, 50.0} has one member.
    let same: (TOMLValue, TOMLValue) -> Bool = { a, b in
        if let x = a.number, let y = b.number { return x == y }
        return a == b
    }
    guard let first = volumes.first, volumes.allSatisfy({ same($0, first) }) else { return nil }
    return first
}

public func readEditable(_ text: String) throws(EditingError) -> EditableConfig {
    let data = try document(text)
    let servers = tables(data, "server")
    let rawDefaults = (data["defaults"] as? [String: Any]) ?? [:]
    let focus = (data["focus"] as? [String: Any]) ?? [:]
    let master = rawDefaults["master_volume"].map(tomlValue) ?? .integer(100)
    var defaults: [String: TOMLValue] = [
        "sound": rawDefaults["sound"].map(tomlValue) ?? .string("chime"),
        "volume": rawDefaults["volume"].map(tomlValue) ?? .integer(60),
        "master_volume": master,
        "notify_channel_messages": rawDefaults["notify_channel_messages"].map(tomlValue) ?? .bool(false),
    ]
    if let shared = sharedServerVolume(servers), let m = master.number, let s = shared.number {
        defaults["master_volume"] = .integer(Int((m * s / 100).rounded(.toNearestOrEven)))
    }
    for key in defaultFields where defaults[key] == nil {
        if let value = rawDefaults[key] {
            defaults[key] = tomlValue(value)
        }
    }
    let hours: TOMLValue
    if case .array(let items)? = focus["quiet_hours"].map(tomlValue) {
        hours = .array(items)
    } else {
        hours = .array([])
    }
    return EditableConfig(
        servers: servers.compactMap { $0["name"] as? String },
        defaults: defaults,
        focus: [
            "mode": focus["mode"].map(tomlValue) ?? .string("off"),
            "quiet_hours": hours,
            "quiet_mode": focus["quiet_mode"].map(tomlValue) ?? .string("silent"),
        ],
        rules: tables(data, "rule").map(editableRule)
    )
}

private func editableRule(_ raw: [String: Any]) -> [String: TOMLValue] {
    var rule: [String: TOMLValue] = [:]
    for key in ruleFields {
        if let value = raw[key] {
            rule[key] = tomlValue(value)
        }
    }
    // Older configs named their rules.
    if rule["description"] == nil, let name = raw["name"].map(tomlValue), name.truthy {
        rule["description"] = name
    }
    for key in ["channel", "sender", "with"] {
        // One value, written bare, is a list of one.
        if let one = rule[key] {
            if case .array = one { continue }
            rule[key] = .array([one])
        }
    }
    return rule
}

/// Highest priority first, then alphabetically by label.
private func sortKey(_ raw: [String: TOMLValue]) -> (Double, String) {
    let priority = -(raw["priority"].flatMap { $0.truthy ? $0.number : 0 } ?? 0)
    var description: String? {
        guard case .string(let text)? = raw["description"], !text.isEmpty else { return nil }
        return text
    }
    let label = sortLabel(raw, description: description) ?? description ?? ""
    return (priority, label.pythonLowercased)
}

/// The label editing.py's Rule(...) would give, or nil where building that
/// Rule raises.
private func sortLabel(_ raw: [String: TOMLValue], description: String?) -> String? {
    let kindName: String
    switch raw["match"] {
    case nil: kindName = "mention"
    case .string(let text)?: kindName = text
    default: return nil
    }
    let isTopic = kindName == "topic"
    var pattern: PyRegex?
    if let source = raw[isTopic ? "topic" : "keyword"], source.truthy {
        guard case .string(let text) = source, let compiled = try? PyRegex(text) else { return nil }
        pattern = compiled
    }
    // tuple(raw.get("channel") or ()): a string becomes its characters.
    var channels: [String] = []
    if let channel = raw["channel"], channel.truthy {
        switch channel {
        case .string(let text): channels = text.map(String.init)
        case .array(let items):
            for item in items {
                guard case .string(let text) = item else { return nil }
                channels.append(text)
            }
        default: return nil
        }
    }
    let people = { (key: String) -> [TOMLValue] in
        if case .array(let items)? = raw[key] { return items }
        return raw[key].map { [$0] } ?? []
    }
    let senders = people("sender").compactMap { if case .string(let name) = $0 { name } else { nil } }
    let senderIDs = people("sender").compactMap { if case .integer(let id) = $0 { id } else { nil } }
    let withIDs = people("with").compactMap { if case .integer(let id) = $0 { id } else { nil } }
    guard let kind = RuleKind(rawValue: kindName),
          let rule = try? Rule(description: description, kind: kind, channels: channels, pattern: pattern,
                               server: nil, sound: nil, volume: nil, banner: nil, priority: 0, index: 0,
                               senders: senders, senderIDs: senderIDs, withIDs: withIDs)
    else { return nil }
    return rule.label
}

private func blank(_ value: TOMLValue?) -> Bool {
    guard let value else { return true }
    return value == .string("")
}

/// A rule's keys as written: in ruleFields order, without blanks or defaults.
private func ruleKeys(_ raw: [String: TOMLValue]) -> [(String, TOMLValue)] {
    var keys: [(String, TOMLValue)] = []
    for key in ruleFields where key != "reaction" && key != "except" {
        var value = raw[key]
        if ["channel", "sender", "with"].contains(key), case .array(let items)? = value {
            let kept = items.filter(\.truthy)
            value = kept.count == 1 ? kept[0] : (kept.isEmpty ? nil : .array(kept))
        }
        if blank(value) || (key == "priority" && value?.number == 0) || (key == "enabled" && value == .bool(true)) {
            continue
        }
        keys.append((key, value!))
    }
    return keys
}

/// New config text with the payload applied, validated by the real parser
/// before it is returned. `sounds` is the sound library for that check.
public func applyEdit(_ text: String, payload: EditPayload, sounds: [String: String]) throws -> String {
    let data = try document(text)
    var spans = try TOMLSpans(text)
    let servers = spans.indices(path: ["server"], isArray: true)

    if payload.defaults?["master_volume"] != nil, sharedServerVolume(tables(data, "server")) != nil {
        // The editor's master already includes a shared server volume.
        for index in servers {
            spans.remove("volume", in: index)
        }
    }

    for (name, fields, keys) in [("defaults", payload.defaults, defaultFields), ("focus", payload.focus, focusFields)] {
        guard let fields else { continue }
        var index = spans.indices(path: [name], isArray: false).first
        if index == nil {
            guard data[name] == nil else {
                throw EditingError(description: "cannot edit this config: [\(name)] is not a plain table")
            }
            spans.append(path: [name], isArray: false, keys: [])
            index = spans.sections.count - 1
        }
        for key in keys {
            if let value = fields[key] {
                spans.set(key, value, in: index!)
            }
        }
    }

    let rawServers = tables(data, "server")
    for edited in payload.servers {
        guard let volume = edited.volume else { continue }
        for (raw, index) in zip(rawServers, servers) where raw["name"] as? String == edited.name {
            spans.set("volume", volume, in: index)
        }
    }

    if let rules = payload.rules {
        spans.removeSections(named: "rule")
        let edited = rules.map { raw -> [String: TOMLValue] in
            var copy = raw
            let description = raw["description"].flatMap { $0.truthy ? $0 : nil } ?? raw["name"]
            copy["description"] = description
            return copy
        }
        // In the order they are tried: priority, then kind, then the order
        // given (the editor's own, which the user can drag).
        let ordered = edited.enumerated().sorted { a, b in
            precedence(a.element, position: a.offset) < precedence(b.element, position: b.offset)
        }.map(\.element)
        for raw in ordered {
            spans.append(path: ["rule"], isArray: true, keys: ruleKeys(raw))
            if case .table(let sub)? = raw["reaction"] {
                let keys = ruleKeys(Dictionary(sub) { $1 })
                if !keys.isEmpty {
                    spans.append(path: ["rule", "reaction"], isArray: false, keys: keys)
                }
            }
            if case .array(let excepts)? = raw["except"] {
                for case .table(let fields) in excepts {
                    spans.append(path: ["rule", "except"], isArray: true, keys: ruleKeys(Dictionary(fields) { $1 }))
                }
            }
        }
    }

    let new = spans.text
    _ = try parseConfig(new, sounds: sounds)
    return new
}

/// Switch the default sound and every rule's sound from old to new, keeping
/// the file's comments and layout. Text without old comes back unchanged.
public func replaceSound(_ text: String, old: String, new: String) throws(EditingError) -> String {
    let data = try document(text)
    var spans = try TOMLSpans(text)
    var changed = false
    if (data["defaults"] as? [String: Any])?["sound"] as? String == old,
       let index = spans.indices(path: ["defaults"], isArray: false).first {
        spans.set("sound", .string(new), in: index)
        changed = true
    }
    for (raw, index) in zip(tables(data, "rule"), spans.indices(path: ["rule"], isArray: true))
    where raw["sound"] as? String == old {
        spans.set("sound", .string(new), in: index)
        changed = true
    }
    return changed ? spans.text : text
}

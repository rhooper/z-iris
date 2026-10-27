import Foundation
import Observation
import ZIrisCore
import ZulipKit

// The rules editor's state and actions (the web editor's script and
// webui.py). The state is the same field dictionaries the web editor sent,
// so a save writes exactly what it did: every edit is applied by itself a
// moment later, through applyEdit, with a .bak copy and an atomic replace.

public struct EditableRule: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var fields: [String: TOMLValue]

    public init(_ fields: [String: TOMLValue]) {
        self.fields = fields
    }

    public static func == (a: EditableRule, b: EditableRule) -> Bool { a.id == b.id && a.fields == b.fields }
}

public struct SoundChoice: Identifiable, Equatable, Sendable {
    public var name: String
    /// One of the user's own, which can be removed.
    public var yours: Bool
    public var id: String { name }
}

public struct SoundInUse: Error, Equatable {
    public var name: String
    public var usedBy: [String]
}

@MainActor
@Observable
public final class EditorModel {
    public var servers: [String] = []
    public var defaults: [String: TOMLValue] = [:]
    public var focus: [String: TOMLValue] = [:]
    public var rules: [EditableRule] = []
    /// Deleted rules wait five minutes to be restored.
    public var deleted: [(rule: EditableRule, index: Int, at: Date)] = []
    public var sounds: [SoundChoice] = []
    public var channels: [String] = []
    public var preview: [ServerPreview]?
    public var status = ""
    public var problem: String?

    @ObservationIgnored public let configPath: String
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let builtinSounds: URL
    @ObservationIgnored private let player: SoundPlayer?
    @ObservationIgnored private let flasher: Flasher?
    @ObservationIgnored private let previews: PreviewSource
    @ObservationIgnored private let channelSource: ChannelSource
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let writeLock = NSLock()

    public init(configPath: String, settings: Settings, builtinSounds: URL, player: SoundPlayer?, flasher: Flasher?,
                previews: PreviewSource = PreviewSource(), channels: ChannelSource = ChannelSource()) {
        self.configPath = configPath
        self.settings = settings
        self.builtinSounds = builtinSounds
        self.player = player
        self.flasher = flasher
        self.previews = previews
        channelSource = channels
    }

    public var userSounds: URL {
        URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("sounds")
    }

    private var library: [String: String] { soundLibrary(builtin: builtinSounds, user: userSounds) }

    private func text() throws -> String {
        try String(contentsOfFile: configPath, encoding: .utf8)
    }

    /// Read the file into the editor.
    public func load() {
        do {
            let editable = try readEditable(try text())
            servers = editable.servers
            defaults = editable.defaults
            focus = editable.focus
            rules = editable.rules.map(EditableRule.init)
            problem = nil
        } catch {
            problem = "\(error)"
        }
        refreshSounds()
    }

    public func loadChannels() async {
        channels = await channelSource.channels(settings.config.servers).all
    }

    public func refreshSounds() {
        let mine = Set(userSoundNames(userSounds))
        sounds = library.keys.filter { $0 != "synth" }.sorted(by: pythonOrder).map { SoundChoice(name: $0, yours: mine.contains($0)) }
    }

    /// What the web editor sent on every save: its whole state.
    public var payload: EditPayload {
        EditPayload(state: EditableConfig(servers: servers, defaults: defaults, focus: focus, rules: rules.map(\.fields)))
    }

    // MARK: saving

    /// Apply edits a moment after the last one (immediately for structural changes).
    public func changed(immediately: Bool = false) {
        status = "Editing…"
        preview = nil
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(immediately ? 50 : 700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Write the edits: validated by the real parser first, the old file kept
    /// as config.toml.bak, then replaced atomically, and the running app
    /// reloads it.
    @discardableResult
    public func save() -> Bool {
        do {
            try writeLock.withLock {
                let new = try applyEdit(try text(), payload: payload, sounds: library)
                let file = URL(fileURLWithPath: configPath)
                let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: file, to: backup)
                try Data(new.utf8).write(to: file, options: .atomic)
            }
            settings.reload(force: true)
            status = "Saved \(Date().formatted(date: .omitted, time: .standard))"
            problem = nil
            return true
        } catch {
            status = "Not applied yet: \(error)"
            problem = "\(error)"
            return false
        }
    }

    // MARK: rules

    public func addRule() {
        rules.append(EditableRule(["match": .string("mention")]))
        changed(immediately: true)
    }

    public func delete(_ rule: EditableRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        deleted.insert((rules.remove(at: index), index, Date()), at: 0)
        changed(immediately: true)
    }

    public func restore(_ rule: EditableRule) {
        guard let index = deleted.firstIndex(where: { $0.rule.id == rule.id }) else { return }
        let entry = deleted.remove(at: index)
        rules.insert(entry.rule, at: min(entry.index, rules.count))
        changed(immediately: true)
    }

    public func forgetOldDeletions(now: Date = Date()) {
        deleted.removeAll { now.timeIntervalSince($0.at) >= 300 }
    }

    /// The rule's label, as the config file's error messages and the menus
    /// name it.
    public func label(_ rule: EditableRule) -> String {
        if case .string(let text)? = rule.fields["description"], !text.isEmpty { return text }
        let kind = RuleKind(rawValue: { if case .string(let k)? = rule.fields["match"] { return k } else { return "mention" } }()) ?? .mention
        var channels: [String] = []
        if case .array(let items)? = rule.fields["channel"] {
            channels = items.compactMap { if case .string(let c) = $0, !c.isEmpty { c } else { nil } }
        }
        let source = { (key: String) -> String? in if case .string(let s)? = rule.fields[key], !s.isEmpty { s } else { nil } }
        let pattern = (kind == .topic ? source("topic") : kind == .keyword ? source("keyword") : nil).flatMap { try? PyRegex($0) }
        return (try? Rule(description: nil, kind: kind, channels: channels.filter { (try? PyRegex($0)) != nil }, pattern: pattern,
                          server: nil, sound: nil, volume: nil, banner: nil, priority: 0, index: 0).label) ?? kind.rawValue
    }

    // MARK: sounds

    /// Play a sound as a rule would: its volume scaled by the master volume.
    public func test(sound: String, volume: Int) {
        let master = settings.config.masterVolume
        guard sound != "none", volume > 0, let path = library[sound] else { return }
        player?.play(path, volume: Int((Double(volume * master) / 100).rounded(.toNearestOrEven)))
    }

    public func addSound(_ file: URL) {
        do {
            let data = try Data(contentsOf: file)
            let name = try ZIrisMac.addSound(userSounds, builtin: builtinSounds, filename: file.lastPathComponent, data: data)
            settings.reload(force: true)
            refreshSounds()
            status = "Added \(name)"
        } catch {
            status = "\(error)"
        }
    }

    /// Remove one of the user's sounds. When the default or a rule uses it,
    /// a replacement is needed and they switch to it first.
    public func removeSound(_ name: String, replacement: String? = nil) throws {
        let text = try text()
        let config = try parseConfig(text, sounds: library)
        let users = (config.sound == name ? ["default sound"] : []) + config.rules.filter { $0.sound == name }.map(\.label)
        if !users.isEmpty {
            guard let replacement else { throw SoundInUse(name: name, usedBy: users) }
            guard replacement != name, replacement == "none" || library[replacement] != nil else {
                throw SoundError(description: "pick another sound to use instead of \(pythonRepr(name))")
            }
            let new = try replaceSound(text, old: name, new: replacement)
            _ = try parseConfig(new, sounds: library)
            try Data(new.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
        try deleteSound(userSounds, builtin: builtinSounds, name: name)
        settings.reload(force: true)
        load()
    }

    // MARK: flash and preview

    public func testFlash(mode: String, color: String, seconds: Double) {
        flasher?.show(mode: mode, color: color, seconds: seconds)
    }

    /// Run recent messages through the draft. Saves nothing.
    public func runPreview(refresh: Bool = false, more: Bool = false) async {
        do {
            let draft = try parseConfig(try applyEdit(try text(), payload: payload, sounds: library), sounds: library)
            status = "Fetching recent messages…"
            preview = await previews.preview(draft, refresh: refresh, more: more)
            status = ""
        } catch {
            status = "\(error)"
        }
    }
}

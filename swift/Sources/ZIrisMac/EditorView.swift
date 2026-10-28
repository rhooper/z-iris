import AppKit
import SwiftUI
import ZIrisCore
import ZulipKit

// The rules editor window. Every control writes into the model's field
// dictionaries; a field left empty in a rule uses the default rule's value.

private let kinds: [(String, String)] = [
    ("topic", "Topic"), ("keyword", "Keyword"), ("mention", "Mention of You"),
    ("wildcard", "Wildcard Mention (@all, @everyone, @channel, @topic)"),
    ("alert_word", "Alert Word (Your Zulip Alert Words)"), ("channel", "Channel"),
    ("group_dm", "Group Direct Message"), ("dm", "Direct Message"),
    ("conversation", "Conversation You're In (Topics You Joined)"), ("reaction", "Reaction to Your Message"),
]
/// Flash styles: the config's value and its menu title.
private let flashModes = [
    ("none", "None"), ("screen", "Full Screen"), ("top", "Top Edge"), ("bottom", "Bottom Edge"),
    ("left", "Left Edge"), ("right", "Right Edge"),
]
private let builtIn: [String: TOMLValue] = [
    "flash": .string("none"), "flash_color": .string("#ff3b30"), "flash_seconds": .float(0.6),
    "repeat": .integer(0), "repeat_every": .integer(30), "repeat_boost": .integer(0),
    "min_gap": .integer(0), "batch_window": .integer(0), "sticky": .bool(false), "stay": .integer(0),
    "summarize": .bool(false), "group_after": .integer(3),
]

enum EditorPane: Hashable {
    case rule(UUID)
    case defaults, general, sounds, preview
}

/// A binding into one key of a field dictionary; nil removes the key.
@MainActor
private func field(_ model: EditorModel, _ fields: Binding<[String: TOMLValue]>, _ key: String) -> Binding<TOMLValue?> {
    Binding(get: { fields.wrappedValue[key] }, set: { value in
        fields.wrappedValue[key] = value
        model.changed()
    })
}

private extension Binding where Value == TOMLValue? {
    var text: Binding<String> {
        Binding<String>(get: { if case .string(let s)? = wrappedValue { s } else { "" } },
                        set: { wrappedValue = $0.isEmpty ? nil : .string($0) })
    }

    var integer: Binding<Int?> {
        Binding<Int?>(get: {
            switch wrappedValue {
            case .integer(let n)?: n
            case .float(let n)?: Int(n)
            default: nil
            }
        }, set: { wrappedValue = $0.map(TOMLValue.integer) })
    }

    var number: Binding<Double?> {
        Binding<Double?>(get: {
            switch wrappedValue {
            case .integer(let n)?: Double(n)
            case .float(let n)?: n
            default: nil
            }
        }, set: { wrappedValue = $0.map(TOMLValue.float) })
    }

    func choice(empty: String = "") -> Binding<String> {
        Binding<String>(get: { if case .string(let s)? = wrappedValue { s } else { empty } },
                        set: { wrappedValue = $0 == empty ? nil : .string($0) })
    }
}

public struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var selection: EditorPane? = .defaults

    public init(model: EditorModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Rules") {
                    ForEach(model.rules) { rule in
                        RuleRow(model: model, rule: rule).tag(EditorPane.rule(rule.id))
                    }
                    Label("Default Rule", systemImage: "circle.dashed").tag(EditorPane.defaults)
                }
                if !model.deleted.isEmpty {
                    Section("Recently Deleted") {
                        ForEach(model.deleted, id: \.rule.id) { entry in
                            HStack {
                                Text(model.label(entry.rule)).strikethrough().foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { model.restore(entry.rule) }
                                    .help("Deleted rules can be restored for five minutes.")
                            }
                        }
                    }
                }
                Section("Settings") {
                    Label("Volume and Focus", systemImage: "speaker.wave.2").tag(EditorPane.general)
                    Label("Sounds", systemImage: "music.note.list").tag(EditorPane.sounds)
                    Label("Preview", systemImage: "eye").tag(EditorPane.preview)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                Button { model.addRule(); selection = model.rules.last.map { .rule($0.id) } } label: {
                    Label("Add rule", systemImage: "plus")
                }
            }
        } detail: {
            Group {
                switch selection {
                case .rule(let id):
                    if let index = model.rules.firstIndex(where: { $0.id == id }) {
                        RuleEditor(model: model, rule: $model.rules[index], onDelete: { model.delete(model.rules[index]); selection = .defaults })
                    } else {
                        Text("No rule selected").foregroundStyle(.secondary)
                    }
                case .defaults, nil: DefaultsEditor(model: model)
                case .general: GeneralEditor(model: model)
                case .sounds: SoundsEditor(model: model)
                case .preview: PreviewPane(model: model)
                }
            }
            .frame(minWidth: 480)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.status).font(.callout).foregroundStyle(model.problem == nil ? Color.secondary : Color.red).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6).background(.bar)
        }
        .task {
            model.load()
            await model.loadChannels()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                model.forgetOldDeletions()
            }
        }
    }
}

private struct RuleRow: View {
    let model: EditorModel
    let rule: EditableRule

    private var accent: Color {
        let flash = { if case .string(let f)? = rule.fields["flash"] { f } else if case .string(let f)? = model.defaults["flash"] { f } else { "none" } }()
        guard flash != "none" else { return .secondary }
        let color = { if case .string(let c)? = rule.fields["flash_color"] { c } else if case .string(let c)? = model.defaults["flash_color"] { c } else { fallbackColor } }()
        let rgb = parseColor(color)
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4, height: 18)
            Text(model.label(rule)).lineLimit(1)
            Spacer()
            if case .integer(let p)? = rule.fields["priority"], p != 0 {
                Text("\(p)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(rule.fields["enabled"] == .bool(false) ? 0.45 : 1)
    }
}

/// A whole-number field that is empty when the rule uses the default.
private struct NumberField: View {
    let title: String
    @Binding var value: Int?
    let inherited: String
    let range: ClosedRange<Int>

    var body: some View {
        TextField(title, value: $value, format: .number, prompt: Text(inherited))
            .help("\(range.lowerBound)–\(range.upperBound); empty uses the default")
    }
}

/// The chosen sound, as a button that opens the sound browser.
private struct SoundPicker: View {
    let model: EditorModel
    @Binding var sound: String
    let volume: Int
    let allowDefault: Bool
    @State private var browsing = false

    private var title: String {
        switch sound {
        case "", "\u{0}": allowDefault ? "Default (\(model.defaultSound))" : model.defaultSound
        case "none": "None (Silent)"
        default: sound
        }
    }

    var body: some View {
        LabeledContent("Sound") {
            Button { browsing = true } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }
            .popover(isPresented: $browsing, arrowEdge: .trailing) {
                SoundBrowser(model: model, sound: $sound, volume: volume, allowDefault: allowDefault) { browsing = false }
            }
        }
    }
}

/// "In Use", naming the rules that use the sound when you hover over it.
private struct InUseBadge: View {
    let users: [String]

    var body: some View {
        Text("In Use")
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .help("Used by " + users.joined(separator: ", "))
    }
}

/// Every sound in two columns, to filter, hear and choose: arrow keys move
/// and play each one; Return or a double-click chooses it.
private struct SoundBrowser: View {
    let model: EditorModel
    @Binding var sound: String
    let volume: Int
    let allowDefault: Bool
    let done: () -> Void
    @State private var query = ""
    @State private var length: SoundLength?
    @State private var pitch: SoundPitch?
    @State private var style: SoundStyle?
    @State private var highlighted: String?
    @FocusState private var gridFocused: Bool

    private static let defaultID = "\u{1}default"

    private struct Item: Identifiable {
        var id: String
        var title: String
        var detail: String
        var users: [String]
    }

    /// What the grid shows, in order: the default and silence first when
    /// nothing narrows the list.
    private func items(_ usage: [String: [String]]) -> [Item] {
        var items: [Item] = []
        if query.isEmpty, length == nil, pitch == nil, style == nil {
            if allowDefault {
                items.append(Item(id: Self.defaultID, title: "Default (\(model.defaultSound))",
                                  detail: "The default rule's sound", users: []))
            }
            items.append(Item(id: "none", title: "None (Silent)", detail: "No sound", users: []))
        }
        return items + filtered.map { Item(id: $0.name, title: $0.name, detail: detail($0), users: usage[$0.name] ?? []) }
    }

    /// Move the highlight by a step through the grid (two to a row).
    private func move(_ step: Int, in items: [Item]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == highlighted }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
        highlighted = items[next].id
        return .handled
    }

    private var filtered: [SoundChoice] {
        model.sounds.filter { choice in
            let measure = model.measures[choice.name]
            return (query.isEmpty || choice.name.localizedCaseInsensitiveContains(query))
                && (style == nil || choice.style == style)
                && (length == nil || measure?.length == length)
                && (pitch == nil || measure?.pitch == pitch)
        }
    }

    private func detail(_ choice: SoundChoice) -> String {
        guard let measure = model.measures[choice.name] else { return choice.style.title }
        return String(format: "%.2f s", measure.seconds) + " · \(measure.pitch.title) · \(choice.style.title)"
    }

    private func play(_ id: String?) {
        guard let id, id != "none" else { return }
        model.test(sound: id == Self.defaultID ? model.defaultSound : id, volume: volume)
    }

    private func choose(_ id: String?) {
        guard let id else { return }
        sound = id == Self.defaultID ? "" : id
        done()
    }

    private func isChosen(_ id: String) -> Bool {
        id == Self.defaultID ? (sound.isEmpty || sound == "\u{0}") : sound == id
    }

    var body: some View {
        let usage = model.soundUsage
        VStack(spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search sounds"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Length", selection: $length) {
                    Text("Any Length").tag(SoundLength?.none)
                    ForEach(SoundLength.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Picker("Pitch", selection: $pitch) {
                    Text("Any Pitch").tag(SoundPitch?.none)
                    ForEach(SoundPitch.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Picker("Style", selection: $style) {
                    Text("All Styles").tag(SoundStyle?.none)
                    ForEach(SoundStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            .labelsHidden()
            let shown = items(usage)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 2) {
                        ForEach(shown) { item in
                            row(item.id, title: item.title, detail: item.detail, users: item.users)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(highlighted == item.id ? Color.accentColor.opacity(0.22) : Color.clear))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { choose(item.id) }
                                .onTapGesture { highlighted = item.id; gridFocused = true }
                                .id(item.id)
                        }
                    }
                    .padding(4)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onKeyPress(.leftArrow) { move(-1, in: shown) }
                .onKeyPress(.rightArrow) { move(1, in: shown) }
                .onKeyPress(.upArrow) { move(-2, in: shown) }
                .onKeyPress(.downArrow) { move(2, in: shown) }
                .onKeyPress(.return) {
                    guard highlighted != nil else { return .ignored }
                    choose(highlighted)
                    return .handled
                }
                .onChange(of: highlighted) {
                    play(highlighted)
                    if let highlighted { withAnimation { scroller.scrollTo(highlighted) } }
                }
            }
            HStack {
                Text("\(filtered.count) of \(model.sounds.count) sounds").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Choose") { choose(highlighted) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(highlighted == nil)
            }
        }
        .padding()
        .frame(width: 660, height: 560)
        .onAppear { highlighted = nil; gridFocused = true }
    }

    private func row(_ id: String, title: String, detail: String, users: [String]) -> some View {
        HStack {
            Button { play(id) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Play")
                .disabled(id == "none")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !users.isEmpty { InUseBadge(users: users) }
            if isChosen(id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

/// Banner, Flash and Repeat: shared by rules (empty uses the default) and
/// the default rule.
private struct BehaviourSections: View {
    let model: EditorModel
    @Binding var fields: [String: TOMLValue]
    let isRule: Bool
    @State private var staySeconds = 30

    private func inherited(_ key: String) -> TOMLValue? {
        isRule ? (model.defaults[key] ?? builtIn[key]) : builtIn[key]
    }

    private func flashTitle(_ value: TOMLValue?) -> String {
        guard case .string(let mode)? = value else { return "None" }
        return flashModes.first { $0.0 == mode }?.1 ?? mode
    }

    private func describe(_ value: TOMLValue?) -> String {
        switch value {
        case .integer(let n)?: "\(n)"
        case .float(let n)?: pythonRepr(n)
        case .string(let s)?: s
        case .bool(let b)?: b ? "On" : "Off"
        default: ""
        }
    }

    private var keep: Binding<String> {
        Binding(get: {
            if fields["sticky"] == .bool(true) { return "read" }
            if case .integer(let n)? = fields["stay"], n > 0 { return "seconds" }
            if fields["sticky"] == .bool(false) || fields["stay"] == .integer(0) { return "fades" }
            return isRule ? "" : "fades"
        }, set: { choice in
            switch choice {
            case "": fields["sticky"] = nil; fields["stay"] = nil
            case "read": fields["sticky"] = .bool(true); fields["stay"] = .integer(0)
            case "seconds": fields["sticky"] = .bool(false); fields["stay"] = .integer(staySeconds)
            default: fields["sticky"] = .bool(false); fields["stay"] = .integer(0)
            }
            model.changed()
        })
    }

    var body: some View {
        Section {
            Picker("Notification", selection: field(model, $fields, "banner").choice()) {
                Text(isRule ? "Default (Show)" : "Show").tag("")
                Text("Title Only").tag("title")
                Text("Off").tag("off")
            }
            Picker("Keep on screen", selection: keep) {
                if isRule { Text("Default").tag("") }
                Text("Fade Away").tag("fades")
                Text("For a Time").tag("seconds")
                Text("Until Read").tag("read")
            }
            if keep.wrappedValue == "seconds" {
                Stepper("For \(staySeconds) seconds", value: Binding(get: { staySeconds }, set: {
                    staySeconds = $0
                    fields["stay"] = .integer($0)
                    model.changed()
                }), in: 1...3600, step: 5)
                .onAppear { if case .integer(let n)? = fields["stay"], n > 0 { staySeconds = n } }
            }
        } header: {
            Text("Banner")
        } footer: {
            Text("For a time or until read, z-iris priority shows an alert that stays until you click it, close it, or read the message elsewhere. Otherwise it's a normal banner that fades away.")
        }
        Section("Flash") {
            Picker("Style", selection: field(model, $fields, "flash").choice()) {
                if isRule { Text("Default (\(flashTitle(inherited("flash"))))").tag("") }
                ForEach(flashModes, id: \.0) { Text($0.1).tag($0.0) }
            }
            ColorPicker("Color", selection: Binding(get: {
                let rgb = parseColor({ if case .string(let c)? = fields["flash_color"] ?? inherited("flash_color") { c } else { fallbackColor } }())
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            }, set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
                fields["flash_color"] = .string(String(format: "#%02x%02x%02x", Int(ns.redComponent * 255 + 0.5),
                                                        Int(ns.greenComponent * 255 + 0.5), Int(ns.blueComponent * 255 + 0.5)))
                model.changed()
            }), supportsOpacity: false)
            TextField("Duration (seconds)", value: field(model, $fields, "flash_seconds").number, format: .number,
                      prompt: Text(describe(inherited("flash_seconds"))))
            Button("Test Flash") {
                let mode = { if case .string(let m)? = fields["flash"] ?? inherited("flash") { m } else { "none" } }()
                guard mode != "none" else { model.status = "Choose a flash style first."; return }
                let color = { if case .string(let c)? = fields["flash_color"] ?? inherited("flash_color") { c } else { fallbackColor } }()
                let seconds = { switch fields["flash_seconds"] ?? inherited("flash_seconds") {
                case .float(let n)?: n
                case .integer(let n)?: Double(n)
                default: 0.6 } }()
                model.testFlash(mode: mode, color: color, seconds: seconds)
            }
        }
        Section {
            NumberField(title: "Repeat count", value: field(model, $fields, "repeat").integer, inherited: describe(inherited("repeat")), range: 0...20)
            NumberField(title: "Repeat interval (seconds)", value: field(model, $fields, "repeat_every").integer, inherited: describe(inherited("repeat_every")), range: 1...3600)
            NumberField(title: "Repeat boost (percentage points)", value: field(model, $fields, "repeat_boost").integer, inherited: describe(inherited("repeat_boost")), range: 0...100)
            NumberField(title: "Minimum gap (seconds)", value: field(model, $fields, "min_gap").integer, inherited: describe(inherited("min_gap")), range: 0...3600)
            NumberField(title: "Batch window (seconds)", value: field(model, $fields, "batch_window").integer, inherited: describe(inherited("batch_window")), range: 0...300)
            NumberField(title: "Group after (number of alerts)", value: field(model, $fields, "group_after").integer, inherited: describe(inherited("group_after")), range: 1...20)
            Picker("Summarize batches", selection: Binding(get: {
                switch fields["summarize"] { case .bool(true)?: "on"; case .bool(false)?: "off"; default: isRule ? "" : "off" }
            }, set: { choice in
                fields["summarize"] = choice.isEmpty ? nil : .bool(choice == "on")
                model.changed()
            })) {
                if isRule { Text("Default (\(describe(inherited("summarize"))))").tag("") }
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .disabled(!ModelSummarizer.available)
            .help(ModelSummarizer.available ? "" : "Needs Apple Intelligence, which is off or not ready on this Mac.")
        } header: {
            Text("Repeat")
        } footer: {
            Text("Repeats play until you read the message, each louder by the boost. The minimum gap skips sound and flash if this rule played that recently; the batch window turns a burst into one summary banner, which Summarize batches rewrites in a sentence on this Mac (Apple Intelligence; nothing is sent anywhere). In a topic you joined, past Group after unread alerts they become one summary alert.")
        }
    }
}

private struct ChannelTokens: View {
    let model: EditorModel
    @Binding var channels: TOMLValue?
    @State private var entry = ""

    private var names: [String] {
        if case .array(let items)? = channels { return items.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        if case .string(let s)? = channels { return [s] }
        return []
    }

    private func set(_ list: [String]) {
        channels = list.isEmpty ? nil : .array(list.map(TOMLValue.string))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack {
                    Text("#\(name)").font(.body.monospaced())
                    Spacer()
                    Button { set(names.enumerated().filter { $0.offset != index }.map(\.element)) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Channel", text: $entry, prompt: Text("Channel name or pattern, such as ops-.*"))
                    .labelsHidden()
                    .frame(minWidth: 220)
                    .onSubmit(add)
                    .textInputSuggestions {
                        ForEach(typed.prefix(12), id: \.self) { Text("#\($0)").textInputCompletion($0) }
                    }
                Button("Add", action: add).disabled(trimmed.isEmpty || pattern == nil)
                Menu("Channels") {
                    ForEach(typed, id: \.self) { name in
                        Button(name) { entry = name; add() }
                    }
                }
                .fixedSize()
            }
            if !trimmed.isEmpty {
                Text(matchSummary).font(.caption).foregroundStyle(pattern == nil ? Color.red : Color.secondary)
            }
        }
    }

    private var trimmed: String { entry.trimmingCharacters(in: .whitespaces) }

    /// Channels whose names contain what is typed, busiest first: all of them, not a sample.
    private var typed: [String] {
        trimmed.isEmpty ? model.channels : model.channels.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The entry as the rule will read it: a pattern for the whole channel name.
    private var pattern: PyRegex? { try? PyRegex(trimmed) }

    private var matchSummary: String {
        guard let pattern else { return "Not a valid pattern." }
        let hits = model.channels.filter { pattern.fullMatch($0) }
        switch hits.count {
        case 0: return model.channels.isEmpty ? "Channels are still loading." : "Matches no channel you can see."
        case 1...4: return "Matches " + hits.map { "#\($0)" }.joined(separator: ", ") + "."
        default: return "Matches " + hits.prefix(3).map { "#\($0)" }.joined(separator: ", ") + " and \(hits.count - 3) more."
        }
    }

    private func add() {
        let name = trimmed
        guard !name.isEmpty, pattern != nil, !names.contains(name) else { return }
        set(names + [name])
        entry = ""
    }
}

private struct RuleEditor: View {
    let model: EditorModel
    @Binding var rule: EditableRule
    let onDelete: () -> Void

    private var match: String { if case .string(let m)? = rule.fields["match"] { m } else { "mention" } }

    var body: some View {
        Form {
            Section {
                TextField("Description", text: field(model, $rule.fields, "description").text, prompt: Text(model.label(rule)))
                Toggle("Enabled", isOn: Binding(get: { rule.fields["enabled"] != .bool(false) },
                                           set: { rule.fields["enabled"] = $0 ? nil : .bool(false); model.changed() }))
                Picker("Match", selection: field(model, $rule.fields, "match").choice(empty: "\u{0}")) {
                    ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                if ["channel", "topic", "conversation", "reaction"].contains(match) {
                    LabeledContent(match == "channel" ? "Channels" : "Channels (optional)") {
                        ChannelTokens(model: model, channels: field(model, $rule.fields, "channel"))
                    }
                }
                if ["topic", "conversation", "reaction"].contains(match) {
                    TextField(match == "topic" ? "Topic (regular expression)" : "Topic (regular expression, optional)",
                              text: field(model, $rule.fields, "topic").text)
                }
                if match == "reaction" {
                    EmojiField(model: model, fields: $rule.fields).id(rule.id)
                }
                if match == "keyword" {
                    TextField("Keyword (regular expression)", text: field(model, $rule.fields, "keyword").text)
                }
                // One server: nothing to choose, unless the rule already names one.
                if model.servers.count > 1 || rule.fields["server"] != nil {
                    Picker("Server", selection: field(model, $rule.fields, "server").choice()) {
                        Text("Any").tag("")
                        ForEach(model.servers, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Priority", value: field(model, $rule.fields, "priority").integer, format: .number, prompt: Text("0"))
                    .help("A higher priority wins over the usual most-specific order.")
                if match != "conversation", match != "reaction" {
                    Toggle("Join this rule's topics", isOn: Binding(get: { rule.fields["join"] == .bool(true) },
                                                                   set: { rule.fields["join"] = $0 ? .bool(true) : nil; model.changed() }))
                        .help("A message this rule matches joins its topic: later messages there alert until it has been quiet for a while.")
                }
            }
            Section {
                SoundPicker(model: model, sound: field(model, $rule.fields, "sound").choice(), volume: volume, allowDefault: true)
                Toggle("Custom volume", isOn: Binding(get: { rule.fields["volume"] != nil }, set: {
                    rule.fields["volume"] = $0 ? .integer(volume) : nil
                    model.changed()
                }))
                if rule.fields["volume"] != nil {
                    Slider(value: Binding(get: { Double(volume) }, set: { rule.fields["volume"] = .integer(Int($0)); model.changed() }),
                           in: 0...100, step: 1) { Text("Volume \(volume)%") }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Without a custom volume, a rule uses the default rule's volume. The master volume scales both.")
            }
            BehaviourSections(model: model, fields: $rule.fields, isRule: true)
            if ["channel", "topic", "conversation"].contains(match) {
                ReactionSection(model: model, fields: $rule.fields, volume: volume)
            }
            Section {
                Button("Delete Rule", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
    }

    private var volume: Int {
        if case .integer(let v)? = rule.fields["volume"] { return v }
        if case .integer(let v)? = model.defaults["volume"] { return v }
        return 60
    }
}

/// A reaction rule's emoji names. The text is kept as typed (a trailing
/// comma included) and only parsed into the rule.
private struct EmojiField: View {
    let model: EditorModel
    @Binding var fields: [String: TOMLValue]
    @State private var text: String

    init(model: EditorModel, fields: Binding<[String: TOMLValue]>) {
        self.model = model
        _fields = fields
        var names: [String] = []
        if case .array(let items)? = fields.wrappedValue["emoji"] {
            names = items.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        _text = State(initialValue: names.joined(separator: ", "))
    }

    var body: some View {
        TextField("Emoji (names, separated by commas)", text: $text, prompt: Text("Any emoji"))
            .help("Zulip's emoji names, such as tada or +1. Leave empty to match any emoji.")
            .onChange(of: text) {
                let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                fields["emoji"] = names.isEmpty ? nil : .array(names.map(TOMLValue.string))
                model.changed()
            }
    }
}

/// A rule's [rule.reaction]: reactions to your messages in the rule's place.
private struct ReactionSection: View {
    let model: EditorModel
    @Binding var fields: [String: TOMLValue]
    let volume: Int

    private var sub: [String: TOMLValue]? {
        guard case .table(let keys)? = fields["reaction"] else { return nil }
        return Dictionary(keys) { $1 }
    }

    private func set(_ key: String, _ value: TOMLValue?) {
        var table = sub ?? [:]
        table[key] = value
        fields["reaction"] = .table(ruleFields.compactMap { name in table[name].map { (name, $0) } })
        model.changed()
    }

    private var subVolume: Int { if case .integer(let v)? = sub?["volume"] { v } else { volume } }

    var body: some View {
        Section {
            if let sub {
                SoundPicker(model: model, sound: Binding(get: { if case .string(let s)? = sub["sound"] { s } else { "" } },
                                                         set: { set("sound", $0.isEmpty ? nil : .string($0)) }),
                            volume: subVolume, allowDefault: true)
                Toggle("Custom volume", isOn: Binding(get: { sub["volume"] != nil }, set: { set("volume", $0 ? .integer(subVolume) : nil) }))
                if sub["volume"] != nil {
                    Slider(value: Binding(get: { Double(subVolume) }, set: { set("volume", .integer(Int($0))) }),
                           in: 0...100, step: 1) { Text("Volume \(subVolume)%") }
                }
                Picker("Notification", selection: Binding(get: { if case .string(let s)? = sub["banner"] { s } else { "" } },
                                                         set: { set("banner", $0.isEmpty ? nil : .string($0)) })) {
                    Text("Default (Show)").tag("")
                    Text("Title Only").tag("title")
                    Text("Off").tag("off")
                }
                Button("Remove Reaction Settings", role: .destructive) {
                    fields["reaction"] = nil
                    model.changed()
                }
            } else {
                Button("Add Reaction Settings") {
                    fields["reaction"] = .table([])
                    model.changed()
                }
            }
        } header: {
            Text("Reactions to Your Messages")
        } footer: {
            Text("When someone reacts to a message you wrote in this rule's channels. Settings left unset come from this rule. Without reaction settings, a reaction shows a banner with no sound.")
        }
    }
}

private struct DefaultsEditor: View {
    @Bindable var model: EditorModel

    private var volume: Int { if case .integer(let v)? = model.defaults["volume"] { v } else { 60 } }

    var body: some View {
        Form {
            Section {
                // Always sent: a save only changes the [defaults] keys it is given.
                SoundPicker(model: model, sound: field(model, $model.defaults, "sound").choice(empty: "\u{0}"), volume: volume, allowDefault: false)
                Slider(value: Binding(get: { Double(volume) }, set: { model.defaults["volume"] = .integer(Int($0)); model.changed() }),
                       in: 0...100, step: 1) { Text("Volume \(volume)%") }
                Toggle("Notify for every channel message", isOn: Binding(get: { model.defaults["notify_channel_messages"] == .bool(true) },
                                                             set: { model.defaults["notify_channel_messages"] = .bool($0); model.changed() }))
                    .help("When this is off, only mentions, direct messages and rules notify. When it's on, every unmuted channel message does too.")
            } header: {
                Text("Default Rule")
            } footer: {
                Text("Applies to everything no other rule matches. Rules without their own sound, volume or settings below use these.")
            }
            BehaviourSections(model: model, fields: $model.defaults, isRule: false)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralEditor: View {
    @Bindable var model: EditorModel

    private var master: Int { if case .integer(let v)? = model.defaults["master_volume"] { v } else { 100 } }

    private var hours: [String] {
        if case .array(let items)? = model.focus["quiet_hours"] { return items.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        return []
    }

    private func setHours(_ list: [String]) {
        model.focus["quiet_hours"] = .array(list.map(TOMLValue.string))
        model.changed(immediately: true)
    }

    private var joinedHours: Int { if case .integer(let v)? = model.defaults["joined_hours"] { v } else { 48 } }

    /// A [defaults] switch that is on unless the file says false.
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { model.defaults[key] != .bool(false) }, set: { model.defaults[key] = .bool($0); model.changed() })
    }

    private func time(_ text: Substring) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    var body: some View {
        Form {
            Section("Volume") {
                Slider(value: Binding(get: { Double(master) }, set: { model.defaults["master_volume"] = .integer(Int($0)); model.changed() }),
                       in: 0...100, step: 1) { Text("Master volume \(master)%") }
                    .help("Scales every sound.")
            }
            Section {
                Picker("Focus now", selection: field(model, $model.focus, "mode").choice(empty: "\u{0}")) {
                    Text("Off").tag("off")
                    Text("Only Direct Messages and Mentions").tag("mentions_and_dms")
                    Text("Silent (Banners Only)").tag("silent")
                }
                ForEach(Array(hours.enumerated()), id: \.offset) { index, entry in
                    let halves = entry.split(separator: "-")
                    HStack {
                        DatePicker("Quiet from", selection: Binding(get: { time(halves.first ?? "22:00") }, set: { start in
                            var list = hours
                            list[index] = clock(start) + "-" + (halves.count > 1 ? String(halves[1]) : "07:00")
                            setHours(list)
                        }), displayedComponents: .hourAndMinute)
                        DatePicker("to", selection: Binding(get: { time(halves.count > 1 ? halves[1] : "07:00") }, set: { end in
                            var list = hours
                            list[index] = String(halves.first ?? "22:00") + "-" + clock(end)
                            setHours(list)
                        }), displayedComponents: .hourAndMinute)
                        Button("Remove") { setHours(hours.enumerated().filter { $0.offset != index }.map(\.element)) }
                    }
                }
                Button("Add Quiet Hours") { setHours(hours + ["22:00-07:00"]) }
                Picker("During quiet hours", selection: field(model, $model.focus, "quiet_mode").choice(empty: "\u{0}")) {
                    Text("Only Direct Messages and Mentions").tag("mentions_and_dms")
                    Text("Silent (Banners Only)").tag("silent")
                }
            } header: {
                Text("Focus and Quiet Hours")
            } footer: {
                Text("Focus applies right away until you turn it off. Quiet hours use local time and can cross midnight, such as 22:00 to 07:00. Only direct messages and mentions: everything else is dropped. Silent: banners still show, without sound or flash.")
            }
            Section {
                Toggle("Join topics where you're mentioned", isOn: flag("join_on_mention"))
                Stepper("Stay joined for \(joinedHours) hours of quiet", value: Binding(get: { joinedHours }, set: {
                    model.defaults["joined_hours"] = .integer($0)
                    model.changed()
                }), in: 1...720)
                Toggle("Notify reactions to your messages", isOn: flag("reactions"))
            } header: {
                Text("Conversations You're In")
            } footer: {
                Text("When you post in a topic, or are mentioned in one, you join it: its messages alert, even during focus, until it has been quiet this long.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundsEditor: View {
    @Bindable var model: EditorModel
    @State private var importing = false
    @State private var inUse: SoundInUse?
    @State private var replacement = "none"

    var body: some View {
        let usage = model.soundUsage
        Form {
            Section {
                ForEach(model.sounds) { sound in
                    HStack {
                        Text(sound.name)
                        if sound.yours { Text("Added by You").font(.caption).foregroundStyle(.secondary) }
                        if let users = usage[sound.name] { InUseBadge(users: users) }
                        Spacer()
                        Button("Play") { model.test(sound: sound.name, volume: 100) }
                        if sound.yours {
                            Button("Remove", role: .destructive) { remove(sound.name, replacement: nil) }
                        }
                    }
                }
                Button("Add Sound…") { importing = true }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Added sounds are stored at the same loudness as the built-in ones. The original file is kept in sounds/originals.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                model.addSound(url)
            }
        }
        .sheet(item: Binding(get: { inUse.map { InUse(value: $0) } }, set: { inUse = $0?.value })) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(item.value.name)” is used by \(item.value.usedBy.joined(separator: ", ")).")
                Picker("Use instead", selection: $replacement) {
                    Text("None (Silent)").tag("none")
                    ForEach(model.sounds.filter { $0.name != item.value.name }) { Text($0.name).tag($0.name) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { inUse = nil }
                    Button("Replace and Remove") {
                        let name = item.value.name
                        inUse = nil
                        remove(name, replacement: replacement)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding().frame(width: 420)
        }
    }

    private struct InUse: Identifiable {
        let value: SoundInUse
        var id: String { value.name }
    }

    private func remove(_ name: String, replacement: String?) {
        do {
            try model.removeSound(name, replacement: replacement)
            model.status = "Removed “\(name)”."
        } catch let error as SoundInUse {
            inUse = error
        } catch {
            model.status = "\(error)"
        }
    }
}

private struct PreviewPane: View {
    @Bindable var model: EditorModel
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Preview Recent Messages") { run(refresh: true) }.disabled(busy)
                if let servers = model.preview, servers.contains(where: { !$0.complete }) {
                    Button("Fetch 1,000 Older") { run(more: true) }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            if let servers = model.preview {
                List {
                    ForEach(servers, id: \.name) { server in
                        Section("\(server.name): \(server.fetched) messages\(server.complete ? ", all" : "")\(server.error.map { " — \($0)" } ?? "")") {
                            ForEach(server.messages, id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(entry.sender) · \(entry.place)").bold()
                                        Spacer()
                                        Text(outcome(entry)).foregroundStyle(entry.notify ? Color.primary : Color.secondary)
                                    }
                                    Text(entry.text).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Runs your last 1,000 messages, and your latest mentions, through the rules as edited, without saving.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func outcome(_ entry: PreviewEntry) -> String {
        guard entry.notify else { return entry.why }
        let rule = entry.ruleIndex.flatMap { $0 < model.rules.count ? model.label(model.rules[$0]) : nil } ?? entry.why
        return "\(rule): \(entry.sound ?? "none") \(entry.volume ?? 0)%"
    }

    private func run(refresh: Bool = false, more: Bool = false) {
        busy = true
        Task {
            await model.runPreview(refresh: refresh, more: more)
            busy = false
        }
    }
}

/// The editor in its own window, opened from the menubar.
@MainActor
public final class EditorWindow {
    private var window: NSWindow?
    private let makeModel: () -> EditorModel

    public init(makeModel: @escaping () -> EditorModel) {
        self.makeModel = makeModel
    }

    public func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(model: makeModel())))
            window.title = "z-iris Rules"
            window.setContentSize(NSSize(width: 900, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

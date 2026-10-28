import Foundation

// What the sound browser knows about each sound: how long it is, how high
// it sounds, what kind of sound it is, and which rules use it.

public enum SoundLength: String, CaseIterable, Sendable {
    case short, medium, long

    public init(seconds: Double) {
        self = seconds < 0.35 ? .short : seconds < 0.8 ? .medium : .long
    }

    public var title: String { rawValue.capitalized }
}

/// How high a sound sounds, from its spectral centroid (the balance point of
/// its spectrum), which follows pitch and brightness together. The bands
/// split the bundled sounds into rough thirds.
public enum SoundPitch: String, CaseIterable, Sendable {
    case low, middle, high

    public init(centroid: Double) {
        self = centroid < 420 ? .low : centroid < 650 ? .middle : .high
    }

    public var title: String { rawValue.capitalized }
}

public enum SoundStyle: String, CaseIterable, Sendable {
    case tones, dx7, synths, drums, recordings, yours

    /// The bundled recordings (SOURCES.md).
    static let recordingNames: Set<String> = [
        "bicycle-bell", "church-bells", "doorbell", "foghorn", "rooster", "singing-bowl", "steam-whistle",
        "typewriter-ding", "wind-chimes",
    ]
    /// The instruments the synth tones are named after (gen_synths.py, gen_moog.py).
    static let synthFamilies: Set<String> = [
        "juno", "tb303", "prophet", "obx", "cs80", "ppg", "d50", "m1", "alpha", "odyssey", "mellotron",
        "fairlight", "jupiter", "sh101", "emulator", "jp8000", "synclavier", "buchla", "omnichord", "moog",
    ]
    /// The drum machines and synth drums the drum tones are named after (gen_drums.py).
    static let drumFamilies: Set<String> = ["808", "909", "syndrum", "cr78"]

    public init(name: String, yours: Bool) {
        let family = name.split(separator: "-").first.map(String.init) ?? name
        if yours {
            self = .yours
        } else if Self.recordingNames.contains(name) {
            self = .recordings
        } else if family == "dx" {
            self = .dx7
        } else if Self.synthFamilies.contains(family) {
            self = .synths
        } else if Self.drumFamilies.contains(family) {
            self = .drums
        } else {
            self = .tones
        }
    }

    public var title: String {
        switch self {
        case .tones: "Tones"
        case .dx7: "DX7"
        case .synths: "Synths"
        case .drums: "Drums"
        case .recordings: "Recordings"
        case .yours: "Yours"
        }
    }
}

/// Which rules use each sound, by label: the default rule, rules that set
/// it, rules that get it as the default sound, and reaction settings.
public func soundUsers(
    defaultSound: String?, rules: [(label: String, sound: String?, reactionSound: String?)]
) -> [String: [String]] {
    var users: [String: [String]] = [:]
    func use(_ sound: String?, _ who: String) {
        guard let sound, sound != "none", !sound.isEmpty else { return }
        users[sound, default: []].append(who)
    }
    use(defaultSound, "Default rule")
    for rule in rules {
        if let sound = rule.sound {
            use(sound, rule.label)
        } else {
            use(defaultSound, "\(rule.label) (default sound)")
        }
        use(rule.reactionSound, "\(rule.label) (reactions)")
    }
    return users
}

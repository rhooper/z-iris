// How a sound feels, for the sound browser: words from the "Character" tags
// of Haken's EaganMatrix vocabulary, as the Expressive E Osmose's presets use
// them (see ~/Devel/synth/synthpi-osmose, osmose/core/tags.py), chosen for
// short notification sounds (twenty-three of its thirty-nine). A sound may
// have several.

public enum SoundFeel: String, CaseIterable, Sendable {
    case acoustic, aggressive, airy, analog, big, bright, clean, dark, digital, distorted, dry, electric, fm, icy
    case intimate, lofi, metallic, nature, simple, soft, synthetic, warm, woody

    public var title: String {
        switch self {
        case .fm: "FM"
        case .lofi: "Lo-fi"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// A bundled sound's feels: its own entry, else its family's (the name
/// before the first hyphen: guitar-e4 is a guitar). Empty for a sound of
/// yours, whose feel is unknown.
public func soundFeels(_ name: String) -> Set<SoundFeel> {
    if let own = feelsByName[name] {
        return own
    }
    let family = name.split(separator: "-").first.map(String.init) ?? name
    return feelsByFamily[family] ?? []
}

private let feelsByFamily: [String: Set<SoundFeel>] = [
    // the short instruments, every note
    "guitar": [.acoustic, .woody, .intimate], "harp": [.acoustic, .soft, .airy], "pizz": [.acoustic, .woody],
    "kalimba": [.acoustic, .woody, .soft], "marimba": [.acoustic, .woody, .warm], "vibes": [.metallic, .warm],
    "celesta": [.metallic, .soft], "musicbox": [.metallic, .intimate, .icy], "steelpan": [.metallic, .bright],
    "glass": [.icy, .airy, .clean], "woodblock": [.woody, .simple], "ocarina": [.airy, .soft, .woody],
    "fmbell": [.digital, .fm, .metallic], "synthpluck": [.analog, .synthetic],
    // synthesizers
    "moog": [.analog, .warm, .aggressive], "juno": [.analog, .warm], "tb303": [.analog, .aggressive],
    "prophet": [.analog, .warm], "obx": [.analog, .big, .bright], "cs80": [.analog, .big, .warm],
    "ppg": [.digital, .icy], "d50": [.digital, .airy], "m1": [.digital, .bright], "alpha": [.analog, .aggressive],
    "odyssey": [.analog, .aggressive], "mellotron": [.lofi, .warm], "fairlight": [.lofi, .digital],
    "jupiter": [.analog, .big], "sh101": [.analog, .synthetic], "emulator": [.lofi, .digital],
    "jp8000": [.digital, .big, .bright], "synclavier": [.digital, .metallic], "buchla": [.analog, .woody],
    "omnichord": [.electric, .airy], "celeste": [.synthetic, .warm],
    // drum machines
    "808": [.analog, .dry], "909": [.analog, .aggressive], "cr78": [.analog, .soft, .lofi],
    "syndrum": [.analog, .synthetic],
    // the FM patches, before their own entries
    "dx": [.digital, .fm],
]

private let feelsByName: [String: Set<SoundFeel>] = [
    // sine and square tones
    "chime": [.clean, .simple, .soft], "ping": [.clean, .simple, .bright], "blip": [.synthetic, .simple],
    "low": [.clean, .warm, .dark], "soft": [.soft, .simple, .warm], "mid-short": [.clean, .simple],
    "mid-long": [.clean, .simple], "bell": [.metallic, .warm], "knock": [.woody, .simple],
    "rise": [.synthetic, .clean], "fall": [.synthetic, .clean], "double": [.clean, .simple, .bright],
    "triple": [.clean, .simple, .bright], "alert": [.clean, .bright], "urgent": [.aggressive, .synthetic, .bright],
    "sos": [.lofi, .distorted],
    // recordings
    "bicycle-bell": [.acoustic, .metallic, .bright], "church-bells": [.acoustic, .metallic, .big],
    "doorbell": [.acoustic, .metallic], "foghorn": [.acoustic, .big, .dark], "rooster": [.acoustic, .nature],
    "singing-bowl": [.acoustic, .metallic, .warm], "steam-whistle": [.acoustic, .big, .bright],
    "typewriter-ding": [.acoustic, .metallic, .bright], "wind-chimes": [.acoustic, .nature, .metallic, .airy],
    // DX7 patches
    "dx-epiano": [.digital, .fm, .electric, .warm], "dx-piano-c": [.digital, .fm, .electric],
    "dx-bells": [.digital, .fm, .metallic, .icy], "dx-marimba": [.digital, .fm, .woody],
    "dx-bass": [.digital, .fm, .dark], "dx-brass": [.digital, .fm, .bright], "dx-vibe": [.digital, .fm, .metallic],
    "dx-koto": [.digital, .fm, .woody], "dx-clav": [.digital, .fm, .electric, .aggressive],
    "dx-harpsichord": [.digital, .fm, .bright], "dx-steel-drum": [.digital, .fm, .metallic, .bright],
    "dx-flute": [.digital, .fm, .airy, .soft], "dx-organ": [.digital, .fm, .electric],
    "dx-strings": [.digital, .fm, .warm], "dx-orch-chime": [.digital, .fm, .metallic, .icy],
    "dx-synlead": [.digital, .fm, .synthetic, .bright],
    // synth patches that differ from their family
    "alpha-hoover": [.analog, .aggressive, .distorted, .big], "tb303-squelch": [.analog, .aggressive, .distorted],
    "juno-pad": [.analog, .warm, .airy], "jp8000-supersaw": [.digital, .big, .bright, .aggressive],
    "ppg-bell": [.digital, .icy, .metallic], "m1-piano": [.digital, .bright, .electric],
    "m1-organ": [.digital, .electric], "m1-universe": [.digital, .big, .airy],
    "synclavier-pad": [.digital, .warm, .soft], "fairlight-orch": [.lofi, .digital, .big, .aggressive],
    "buchla-chime": [.analog, .metallic], "odyssey-ring": [.analog, .metallic],
    "mellotron-flute": [.lofi, .airy, .soft], "emulator-shakuhachi": [.lofi, .airy, .woody],
    "d50-fantasia": [.digital, .airy, .icy], "omnichord-organ": [.electric, .simple],
    // Celeste's instruments
    "celeste-piano": [.acoustic, .intimate, .soft], "celeste-rhodes": [.electric, .warm],
    "celeste-arp": [.synthetic, .bright], "celeste-pad": [.synthetic, .warm, .airy],
    "celeste-crystal": [.icy, .metallic, .bright], "celeste-chip": [.lofi, .digital, .simple],
    "celeste-sparkle": [.bright, .airy, .icy], "celeste-bass": [.analog, .warm, .dark],
    // drums that differ from their machine
    "808-cowbell": [.analog, .metallic], "808-clave": [.analog, .woody, .dry],
    "909-roll": [.analog, .aggressive, .big],
]

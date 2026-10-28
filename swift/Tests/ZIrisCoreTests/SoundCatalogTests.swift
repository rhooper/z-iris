import Testing
@testable import ZIrisCore

@Suite struct SoundCatalogTests {
    @Test func lengthBands() {
        #expect(SoundLength(seconds: 0.06) == .short && SoundLength(seconds: 0.34) == .short)
        #expect(SoundLength(seconds: 0.35) == .medium && SoundLength(seconds: 0.79) == .medium)
        #expect(SoundLength(seconds: 0.8) == .long && SoundLength(seconds: 3) == .long)
    }

    @Test func pitchBands() {
        #expect(SoundPitch(centroid: 300) == .low)
        #expect(SoundPitch(centroid: 500) == .middle)
        #expect(SoundPitch(centroid: 4000) == .high)
    }

    @Test func styles() {
        #expect(SoundStyle(name: "chime", yours: false) == .tones)
        #expect(SoundStyle(name: "sos", yours: false) == .tones)
        #expect(SoundStyle(name: "dx-brass", yours: false) == .dx7)
        #expect(SoundStyle(name: "juno-pad", yours: false) == .synths)
        #expect(SoundStyle(name: "moog-a", yours: false) == .synths)
        #expect(SoundStyle(name: "omnichord-harp", yours: false) == .synths)
        #expect(SoundStyle(name: "rooster", yours: false) == .recordings)
        #expect(SoundStyle(name: "808-cowbell", yours: false) == .drums)
        #expect(SoundStyle(name: "simmons-fill", yours: false) == .drums)
        #expect(SoundStyle(name: "klaxon", yours: true) == .yours)
        #expect(SoundStyle.allCases.map(\.title) == ["Tones", "DX7", "Synths", "Drums", "Recordings", "Yours"])
    }

    @Test func whoUsesWhat() {
        let users = soundUsers(defaultSound: "moog-a", rules: [
            (label: "DM", sound: "dx-brass", reactionSound: nil),
            (label: "Channel #ops", sound: nil, reactionSound: "soft"),
            (label: "Mention", sound: "dx-brass", reactionSound: nil),
        ])
        #expect(users["dx-brass"] == ["DM", "Mention"])
        #expect(users["moog-a"] == ["Default rule", "Channel #ops (default sound)"])
        #expect(users["soft"] == ["Channel #ops (reactions)"])
        #expect(users["chime"] == nil)
        #expect(soundUsers(defaultSound: "none", rules: [(label: "X", sound: nil, reactionSound: nil)]).isEmpty)
    }
}

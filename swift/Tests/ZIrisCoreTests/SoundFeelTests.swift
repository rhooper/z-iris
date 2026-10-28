import Testing
@testable import ZIrisCore

@Suite struct SoundFeelTests {
    @Test func feelsComeFromTheSoundOrItsFamily() {
        #expect(soundFeels("guitar-e4") == [.acoustic, .woody, .intimate])  // by family, any note
        #expect(soundFeels("dx-bells").isSuperset(of: [.digital, .fm, .metallic]))  // by name
        #expect(soundFeels("moog-c4-long").contains(.analog))
        #expect(soundFeels("alpha-hoover").contains(.aggressive))
        #expect(soundFeels("klaxon").isEmpty)  // one of yours: no feel known
    }

    @Test func feelNamesAreOsmoseCharacterNames() {
        #expect(SoundFeel.lofi.title == "Lo-fi" && SoundFeel.fm.title == "FM" && SoundFeel.warm.title == "Warm")
        #expect(SoundFeel.allCases.map(\.title) == SoundFeel.allCases.map(\.title).sorted())  // alphabetical, as the Osmose lists them
    }
}

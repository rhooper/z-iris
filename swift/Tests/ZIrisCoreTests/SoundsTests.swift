import Foundation
import Testing
import ZIrisCore

@Suite struct SoundsTests {
    private let builtin = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/sounds").standardized

    @Test func userFilesWinAndOddFilesAreSkipped() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: user.appendingPathComponent("folder.wav"), withIntermediateDirectories: true)
        for name in ["chime.MP3", "mine.caf", ".hidden.wav", "notes.txt", "noext"] {
            try Data().write(to: user.appendingPathComponent(name))
        }
        let sounds = soundLibrary(builtin: builtin, user: user)
        #expect(sounds["chime"] == user.appendingPathComponent("chime.MP3").path)
        #expect(sounds["synth"] == builtin.appendingPathComponent("chime.wav").path)
        #expect(sounds["mine"] != nil)
        #expect(sounds["ping"] == builtin.appendingPathComponent("ping.wav").path)
        for missing in [".hidden", "notes", "noext", "folder"] {
            #expect(sounds[missing] == nil)
        }
    }
}

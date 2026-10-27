import AVFoundation
import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

@Suite struct SoundLibraryTests {
    private let builtin = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/sounds").standardized

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-user-sounds-\(UUID().uuidString)")
    }

    private func tone() throws -> Data {
        try Data(contentsOf: builtin.appendingPathComponent("ping.wav"))
    }

    @Test func addingStoresANormalizedWavAndKeepsTheOriginal() throws {
        let user = folder()
        let name = try addSound(user, builtin: builtin, filename: "My Bell!.caf", data: tone())
        #expect(name == "My Bell")
        #expect(userSoundNames(user) == ["My Bell"])
        let stored = user.appendingPathComponent("My Bell.wav")
        let levels = try #require(soundLevels(stored))
        #expect(abs(gainFor(peak: levels.peak, rms: levels.rms) - 1) < 0.1 || levels.peak > 0.98)
        #expect(FileManager.default.fileExists(atPath: user.appendingPathComponent("originals/My Bell.caf").path))
        try deleteSound(user, builtin: builtin, name: "My Bell")
        #expect(userSoundNames(user).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("originals/My Bell.caf").path))
    }

    @Test func refusals() throws {
        let user = folder()
        let cases: [(String, Data, String)] = [
            ("a.wav", Data(count: maxSoundBytes + 1), "file is too large (10 MB limit)"),
            ("../a.wav", Data(), "bad file name"),
            (".hidden.wav", Data(), "bad file name"),
            ("a.txt", Data(), "file type must be one of .wav, .aiff, .aif, .flac, .mp3, .ogg, .caf"),
            ("none.wav", Data(), "bad sound name"),
            ("!!!.wav", Data(), "bad sound name"),
            ("PING.wav", Data(), "a sound named \"PING\" already exists; rename the file"),
            ("noise.wav", Data("not audio".utf8), "this file cannot be played"),
        ]
        for (filename, data, message) in cases {
            #expect(throws: SoundError(description: message)) { try addSound(user, builtin: builtin, filename: filename, data: data) }
        }
        #expect(throws: SoundError(description: "\"ping\" is a bundled tone and cannot be deleted")) {
            try deleteSound(user, builtin: builtin, name: "ping")
        }
        #expect(throws: SoundError(description: "no sound of yours is named \"x\"")) {
            try deleteSound(user, builtin: builtin, name: "x")
        }
    }
}

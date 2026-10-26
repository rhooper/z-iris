import Foundation
import Testing
@testable import ZIrisCore

@Suite struct SettingsTests {
    private let sounds = ["chime": "/c.wav", "ping": "/p.wav"]

    private func write(_ text: String, to url: URL, at seconds: Double) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    @Test func reloadsOnChangeKeepsTheLastGoodConfigAndRefusesServerChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.toml")
        let server = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"
        try write(server + "[defaults]\nvolume = 10\n", to: file, at: 1000)
        let sounds = self.sounds
        let settings = Settings(try loadConfig(at: file.path, sounds: sounds), path: file.path, sounds: { sounds })
        #expect(settings.reload() == nil && settings.config.volume == 10)

        try write(server + "[defaults]\nvolume = 20\n", to: file, at: 1001)
        #expect(settings.reload() == nil && settings.config.volume == 20)

        try write(server + "[defaults]\nvolume = 500\n", to: file, at: 1002)
        #expect(settings.reload() == "volume must be an integer from 0 to 100")
        #expect(settings.config.volume == 20)
        #expect(settings.reload() == "volume must be an integer from 0 to 100")  // unchanged file, same answer

        try write("[[server]]\nname = \"home\"\nzuliprc = \"/y\"\n[defaults]\nvolume = 30\n", to: file, at: 1003)
        #expect(settings.reload() == restartMessage)
        #expect(settings.config.volume == 30 && settings.config.servers.map(\.name) == ["w"])

        try write(server + "[defaults]\nvolume = 40\n", to: file, at: 1003)  // same time: only a forced reload sees it
        #expect(settings.reload() == restartMessage && settings.config.volume == 30)
        #expect(settings.reload(force: true) == nil && settings.config.volume == 40)
    }
}

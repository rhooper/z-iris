import Foundation
import Testing
@testable import ZIrisMac

@Suite struct LogTests {
    @Test func writesWhenNotATerminalAndKeepsOneBackup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-log-\(UUID().uuidString)/z-iris.log")
        logProblem("first", to: url, tty: false, cap: 10)
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix(" first\n"))
        logProblem("second", to: url, tty: false, cap: 10)
        let backup = url.deletingLastPathComponent().appendingPathComponent("z-iris.log.1")
        #expect(try String(contentsOf: backup, encoding: .utf8).hasSuffix(" first\n"))
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix(" second\n"))
        logProblem("quiet", to: url.deletingLastPathComponent().appendingPathComponent("tty.log"), tty: true)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("tty.log").path))
    }
}

import Foundation

// Problems go to stderr and, when stderr goes nowhere (Finder, a login item),
// to ~/Library/Logs/z-iris.log too, with one .1 backup (notify.log_problem).

public let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/z-iris.log")
public let logCap = 256 * 1024

private let logLock = NSLock()

public func logProblem(_ text: String, to url: URL = logURL, tty: Bool? = nil, cap: Int = logCap) {
    FileHandle.standardError.write(Data("z-iris: \(text)\n".utf8))
    if tty ?? (isatty(STDERR_FILENO) != 0) {
        return
    }
    logLock.withLock {
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= cap {
            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            _ = try? files.replaceItemAt(backup, withItemAt: url)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let line = Data("\(formatter.string(from: Date())) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

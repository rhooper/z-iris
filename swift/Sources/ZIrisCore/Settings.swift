import Foundation

// The current config, swapped when the file changes (settings.py). A file
// that does not parse never replaces a good config, and server changes need
// a restart: the streams are per server.

public let restartMessage = "servers changed, restart z-iris"

public final class Settings: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Config
    private var problem: String?
    private var modified: Date?
    public let path: String?
    private let sounds: @Sendable () -> [String: String]

    /// - Parameter sounds: the sound library, read again on each reload.
    public init(_ config: Config, path: String? = nil, sounds: @escaping @Sendable () -> [String: String] = { [:] }) {
        current = config
        self.path = path
        self.sounds = sounds
        modified = Self.modificationDate(path)
    }

    public var config: Config { lock.withLock { current } }
    public var error: String? { lock.withLock { problem } }

    private static func modificationDate(_ path: String?) -> Date? {
        path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
    }

    /// Re-read the file if it changed (always, when forced). Returns the
    /// current problem, or nil.
    @discardableResult
    public func reload(force: Bool = false) -> String? {
        guard let path else { return nil }
        let date = Self.modificationDate(path)
        if !force, date == lock.withLock({ modified }) {
            return error
        }
        let old = config
        let new: Config
        do {
            new = try loadConfig(at: path, sounds: sounds())
        } catch {
            return set(old, error.description, date)
        }
        if new.servers.map({ [$0.name, $0.zuliprc] }) != old.servers.map({ [$0.name, $0.zuliprc] }) {
            var kept = new
            kept.servers = old.servers
            return set(kept, restartMessage, date)
        }
        return set(new, nil, date)
    }

    private func set(_ config: Config, _ error: String?, _ date: Date?) -> String? {
        lock.withLock {
            current = config
            problem = error
            modified = date
        }
        return error
    }
}

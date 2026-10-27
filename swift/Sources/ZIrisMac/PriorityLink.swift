import Foundation
import ZIrisCore

// Hand sticky alerts to z-iris-priority.app (prioritylink.py): its executable
// runs as a child; each request is one JSON line on its stdin and gets one
// JSON line back. Anything that goes wrong (no app, no permission, a hang, a
// crash) shows an ordinary banner instead, so a sticky message is never lost.

public let priorityApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/z-iris-priority.app")

public func priorityExecutable(_ app: URL = priorityApp) -> URL {
    app.appendingPathComponent("Contents/MacOS/z-iris-priority")
}

/// One running helper.
public protocol PriorityChild: AnyObject {
    var alive: Bool { get }
    /// Set when it was killed for not answering: restarting would not help.
    var hung: Bool { get }
    /// The reply, or nil if it died, hung or answered nonsense.
    func ask(_ request: [String: Any], timeout: Double) -> [String: Any]?
}

/// The helper as a child process with pipes.
public final class ProcessChild: PriorityChild, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let replies = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var lines: [String?] = []
    private var buffer = Data()
    public private(set) var hung = false

    public init(_ executable: URL, arguments: [String] = []) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data)
        }
        try process.run()
    }

    private func received(_ data: Data) {
        lock.withLock {
            if data.isEmpty {
                lines.append(nil)  // end of output
                replies.signal()
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
                buffer.removeSubrange(...newline)
                replies.signal()
            }
        }
    }

    public var alive: Bool { process.isRunning }

    public func ask(_ request: [String: Any], timeout: Double) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        } catch {
            return nil  // the pipe is closed: it died
        }
        guard replies.wait(timeout: .now() + timeout) == .success else {
            hung = true
            kill()  // a late reply would answer the next request
            return nil
        }
        guard let line = lock.withLock({ lines.removeFirst() }) else { return nil }
        guard let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            hung = true
            kill()
            return nil
        }
        return reply
    }

    func kill() {
        if process.isRunning { process.terminate() }
    }
}

/// Persistent alerts through z-iris-priority. show and clear block for at
/// most about two timeouts: call them from the banner worker, never the engine.
public final class PriorityLink: Notifying, @unchecked Sendable {
    private let fallback: any Notifying
    private let app: URL
    private let start: (URL) throws -> any PriorityChild
    private let warn: (String) -> Void
    private let timeout: Double
    private let lock = NSLock()
    private var child: (any PriorityChild)?
    private var state: String?
    private var styleWarned = false
    private var why = "no reply"
    private var clearFailing = false
    private var plainWarned = false

    public init(
        fallback: any Notifying, app: URL = priorityApp,
        start: @escaping (URL) throws -> any PriorityChild = { try ProcessChild($0) },
        warn: @escaping (String) -> Void = { logProblem($0) }, timeout: Double = 2
    ) {
        self.fallback = fallback
        self.app = app
        self.start = start
        self.warn = warn
        self.timeout = timeout
    }

    private func transition(_ next: String, _ text: String) {
        if state != next {
            state = next
            warn(text)
        }
    }

    private func running() -> (any PriorityChild)? {
        if let child, child.alive {
            return child
        }
        let path = priorityExecutable(app)
        guard FileManager.default.fileExists(atPath: path.path) else {
            why = "no z-iris priority at \(app.path)"
            return nil
        }
        let started: any PriorityChild
        do {
            started = try start(path)
        } catch {
            why = "cannot start it: \(error.localizedDescription)"
            return nil
        }
        guard let status = started.ask(["op": "status"], timeout: timeout) else {
            why = "no reply"
            return nil
        }
        child = started
        let style = status["style"] as? String
        if (status["allowed"] as? Bool) == true, style != "alert", !styleWarned {
            styleWarned = true
            warn("z-iris priority alerts are set to \(style ?? "None"); set Alerts in System Settings, Notifications, z-iris priority")
        }
        return started
    }

    private func request(_ body: [String: Any]) -> [String: Any]? {
        for _ in 0..<2 {  // one restart if the child has died
            guard let current = running() else { return nil }
            if let reply = current.ask(body, timeout: timeout) {
                return reply
            }
            why = "no reply"
            if current.hung {  // restarting would only hang again
                return nil
            }
        }
        return nil
    }

    public func show(title: String, body: String, url: String, image: String?, group: String?, sender: Sender?,
                     thread: String?) async {
        var body_: [String: Any] = [
            "op": "show", "title": title, "body": body, "url": url,
            "group": group ?? "z-iris", "image": image as Any? ?? NSNull(),
        ]
        if let thread {
            body_["thread"] = thread
        }
        if let sender {
            body_["sender"] = sender.toJSON()
        }
        let failed: String? = lock.withLock {
            let reply = request(body_)
            if let reply, (reply["ok"] as? Bool) == true {
                if let plain = reply["plain"] as? String, !plain.isEmpty, !plainWarned {
                    plainWarned = true
                    warn("sender icons unavailable in z-iris priority (\(plain)); plain alerts")
                }
                if state != nil, state != "native" {
                    transition("native", "z-iris priority alerts working again")
                }
                state = "native"
                return nil
            }
            let reason = reply.map { ($0["reason"] as? String) ?? "None" } ?? why
            transition("fallback", "z-iris priority did not show an alert (\(reason)); using a banner")
            return reason
        }
        if failed != nil {
            await fallback.show(title: title, body: body, url: url, image: image, group: group, sender: sender, thread: thread)
        }
    }

    public func clear(_ group: String) async {
        clearGroups([group])
    }

    public func clearGroups(_ groups: [String]) {
        clear(["op": "clear", "groups": groups])
    }

    /// keepGroups: conversation summaries still showing for unread topics.
    public func clearThread(_ thread: String) {
        clear(["op": "clear_thread", "thread": thread])
    }

    public func clearServer(_ server: String, keep: Set<Int>, keepGroups: Set<String> = []) {
        clear(["op": "clear_server", "server": server, "keep": keep.sorted(), "keep_groups": keepGroups.sorted()])
    }

    private func clear(_ body: [String: Any]) {
        guard FileManager.default.fileExists(atPath: priorityExecutable(app).path) else {
            return  // no app, so no alerts to clear
        }
        lock.withLock {
            let reply = request(body)
            if let reply, (reply["ok"] as? Bool) == true {
                clearFailing = false
            } else if !clearFailing {
                clearFailing = true
                let reason = reply.map { ($0["reason"] as? String) ?? "None" } ?? why
                warn("z-iris priority could not clear alerts (\(reason))")
            }
        }
    }
}

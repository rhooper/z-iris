import Foundation
import Testing
@testable import ZIrisCore

/// tests/test_engine.py's FakeClock: due timers run in (due, sequence) order,
/// moving the clock to each one's time.
final class TestScheduler: Scheduler, @unchecked Sendable {
    private final class Timer: Cancellable, @unchecked Sendable {
        let due: Double
        let sequence: Int
        let work: @Sendable () async -> Void
        var cancelled = false

        init(due: Double, sequence: Int, work: @escaping @Sendable () async -> Void) {
            self.due = due
            self.sequence = sequence
            self.work = work
        }

        func cancel() { cancelled = true }
    }

    // Tests drive this from one task at a time, so plain state is enough.
    private(set) var now = 1000.0
    private var timers: [Timer] = []
    private var sequence = 0

    func schedule(after seconds: Double, _ work: @escaping @Sendable () async -> Void) -> any Cancellable {
        sequence += 1
        let timer = Timer(due: now + seconds, sequence: sequence, work: work)
        timers.append(timer)
        return timer
    }

    func advance(_ seconds: Double) async {
        let end = now + seconds
        while let timer = timers.filter({ !$0.cancelled && $0.due <= end })
            .min(by: { ($0.due, $0.sequence) < ($1.due, $1.sequence) }) {
            timer.cancelled = true
            now = max(now, timer.due)
            await timer.work()
        }
        now = end
    }
}

final class Trace: EngineOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    let clock: @Sendable () -> Double

    init(clock: @escaping @Sendable () -> Double) {
        self.clock = clock
    }

    var entries: [[String: Any]] { lock.withLock { recorded } }

    func add(_ entry: [String: Any]) {
        lock.withLock { recorded.append(entry) }
    }

    private func note(_ call: String, _ n: ZIrisCore.Notification, _ extra: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "t": clock(), "call": call, "server": n.message.server, "id": n.message.id,
            "sound": n.action.sound, "flash": n.action.flash, "volume": n.action.volume,
            "summary": n.summary as Any? ?? NSNull(),
        ]
        entry.merge(extra) { $1 }
        add(entry)
    }

    func deliver(_ notification: ZIrisCore.Notification) { note("deliver", notification) }
    func banner(_ notification: ZIrisCore.Notification) { note("banner", notification) }
    func sound(_ notification: ZIrisCore.Notification, volume: Int?) {
        note("sound", notification, ["at": volume as Any? ?? NSNull()])
    }
    func clearRead(server: String, ids: Set<Int>?) {
        add(["t": clock(), "call": "clear_read", "server": server, "ids": ids.map { $0.sorted() } as Any? ?? NSNull()])
    }
    func clearUnlessUnread(server: String, unread: Set<Int>) {
        add(["t": clock(), "call": "clear_unless_unread", "server": server, "ids": unread.sorted()])
    }
}

extension Action {
    /// An Action as gen_fixtures.py writes it (Python field names).
    init(fixture d: [String: Any]) {
        self.init(sound: d["sound"] as! String, volume: d["volume"] as! Int, banner: d["banner"] as! String,
                  rule: d["rule"] as? String)
        flash = d["flash"] as! String
        flashColor = d["flash_color"] as! String
        flashSeconds = (d["flash_seconds"] as! NSNumber).doubleValue
        `repeat` = d["repeat"] as! Int
        repeatEvery = d["repeat_every"] as! Int
        repeatBoost = d["repeat_boost"] as! Int
        minGap = d["min_gap"] as! Int
        batchWindow = d["batch_window"] as! Int
        sticky = d["sticky"] as! Bool
        stay = d["stay"] as! Int
        ruleIndex = d["rule_index"] as? Int
    }
}

/// Settings the trace can change between steps.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct EngineParity {
    @Test(arguments: Fixture.load("engine"))
    func trace(_ fixture: Fixture) async throws {
        let scheduler = TestScheduler()
        let config = Box(try parseConfig(fixture.input["toml"] as! String, sounds: fixtureSounds))
        let paused = Box(false)
        let minutes = Box(12 * 60)
        let trace = Trace(clock: { scheduler.now })
        let engine = Engine(
            output: trace, config: { config.current }, isPaused: { paused.current },
            clock: { scheduler.now }, scheduler: scheduler, localMinutes: { minutes.current },
            log: { text in trace.add(["t": scheduler.now, "log": text]) }
        )
        for step in fixture.input["steps"] as! [[String: Any]] {
            switch step["op"] as! String {
            case "submit":
                let message = Message(fixture: step["message"] as! [String: Any])
                await engine.submit(ZIrisCore.Notification(
                    message: message, url: narrowURL(message), reason: step["reason"] as! String,
                    action: Action(fixture: step["action"] as! [String: Any])
                ))
            case "event":
                if let event = ReadEvent(step["event"] as! [String: Any]) {
                    await engine.handle(server: step["server"] as! String, event)
                }
            case "advance":
                await scheduler.advance((step["seconds"] as! NSNumber).doubleValue)
            case "pause": paused.current = true
            case "resume": paused.current = false
            case "reconcile":
                await engine.reconcileUnread(server: step["server"] as! String, unread: Set(step["unread"] as! [Int]))
            case "stop": await engine.stop()
            case "minutes": minutes.current = step["value"] as! Int
            case "config": config.current = try parseConfig(step["toml"] as! String, sounds: fixtureSounds)
            default: Issue.record("unknown step \(step)")
            }
        }
        let got = trace.entries
        let want = fixture.expected as! [[String: Any]]
        #expect(got.count == want.count, "\(got.count) entries, want \(want.count)")
        for (index, (entry, expected)) in zip(got, want).enumerated() {
            #expect(NSDictionary(dictionary: entry) == NSDictionary(dictionary: expected), "entry \(index): \(entry)\nwant \(expected)")
        }
    }

    @Test(arguments: Fixture.load("pipeline"))
    func pipeline(_ fixture: Fixture) throws {
        let config = try parseConfig(fixture.input["toml"] as! String, sounds: fixtureSounds)
        var pipeline = Pipeline(
            server: "work", host: "chat.example.com", selfID: 5,
            mutes: try MuteState(register: fixture.input["register"] as! [String: Any]),
            config: { config }
        )
        let events = fixture.input["events"] as! [[String: Any]]
        let want = fixture.expected as! [Any]
        for (event, expected) in zip(events, want) {
            let got = pipeline.handle(event)
            guard let expected = expected as? [String: Any] else {
                #expect(got == nil, "\(event)")
                continue
            }
            #expect(got?.message.id == expected["id"] as? Int)
            #expect(got?.url == expected["url"] as? String)
            #expect(got?.reason == expected["reason"] as? String)
            #expect(got?.action == Action(fixture: expected["action"] as! [String: Any]))
        }
    }
}

import Foundation

// Schedule notifications between the pipeline and the output: focus,
// min_gap, batching, repeats and read awareness. The clock and scheduler are
// injected, so tests run on a fake clock (TestScheduler).

/// Where the engine sends notifications. Calls must not block: the real
/// output queues the work.
public protocol EngineOutput: Sendable {
    func deliver(_ notification: Notification)
    func banner(_ notification: Notification)
    func sound(_ notification: Notification, volume: Int?)
    func clearRead(server: String, ids: Set<Int>?)
    func clearUnlessUnread(server: String, unread: Set<Int>)
    /// One alert for a conversation's unread messages, replacing their own.
    func conversationSummary(_ key: TopicKey, _ unread: [Notification])
    /// The conversation was read: its summary goes.
    func clearConversation(_ key: TopicKey)
}

extension EngineOutput {
    public func conversationSummary(_ key: TopicKey, _ unread: [Notification]) {}
    public func clearConversation(_ key: TopicKey) {}
}

public protocol Cancellable: Sendable {
    func cancel()
}

public protocol Scheduler: Sendable {
    func schedule(after seconds: Double, _ work: @escaping @Sendable () async -> Void) -> any Cancellable
}

/// Runs work after a delay on a Task; cancelling stops one not yet run.
public struct TaskScheduler: Scheduler {
    public init() {}

    private struct Handle: Cancellable {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    public func schedule(after seconds: Double, _ work: @escaping @Sendable () async -> Void) -> any Cancellable {
        Handle(task: Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled {
                await work()
            }
        })
    }
}

/// Whether a minute of the day falls in any window. Windows may cross midnight.
public func quietNow(_ hours: [FocusConfig.QuietHours], minute: Int) -> Bool {
    hours.contains { window in
        if window.start < window.end {
            return window.start <= minute && minute < window.end
        }
        return window.start > window.end && (minute >= window.start || minute < window.end)
    }
}

public func localMinutes() -> Int {
    let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
    return now.hour! * 60 + now.minute!
}

private func personal(_ notification: Notification) -> Bool {
    let message = notification.message
    if notification.reason == "reaction" {
        return false  // reactions to your direct messages are not direct messages
    }
    return message.kind == .dm || message.isMention || message.isWildcardMention || notification.conversation != nil
}

func audible(_ notification: Notification) -> Bool {
    notification.action.sound != "none" && notification.action.volume > 0
}

/// The same notification without sound or flash, for banner-only delivery.
private func stripped(_ notification: Notification) -> Notification {
    var copy = notification
    copy.action.sound = "none"
    copy.action.flash = "none"
    return copy
}

/// What counts as the same source: the rule, else the conversation.
private enum SourceKey: Hashable {
    case ruleIndex(Int)
    case ruleLabel(String)
    case channel(server: String, id: Int?, topic: String?)
    case dm(server: String, ids: [Int])

    init(_ notification: Notification) {
        let action = notification.action, message = notification.message
        if let index = action.ruleIndex {
            self = .ruleIndex(index)
        } else if let label = action.rule, !label.isEmpty {
            self = .ruleLabel(label)
        } else if message.kind == .channel {
            self = .channel(server: message.server, id: message.channelID, topic: message.topic)
        } else {
            self = .dm(server: message.server, ids: message.dmUserIDs)
        }
    }
}

private enum Conversation: Hashable {
    case channel(server: String, id: Int?)
    case dm(server: String, ids: [Int])

    init(_ notification: Notification) {
        let message = notification.message
        self = message.kind == .channel
            ? .channel(server: message.server, id: message.channelID)
            : .dm(server: message.server, ids: message.dmUserIDs)
    }
}

/// Conversations are channels (any topic) or DM groups, per server.
private func summary(_ held: [Notification]) -> String {
    let conversations = Set(held.map(Conversation.init))
    let latest = held.last!.message
    let place: String
    if conversations.count > 1 {
        place = "in \(conversations.count) conversations"
    } else if latest.kind == .channel {
        place = "in #\(latest.channelName ?? "None")"
    } else if latest.dmUserIDs.count > 1 {
        place = "in a group chat"
    } else {
        place = "from \(latest.senderName)"
    }
    return "\(held.count) new \(place)"
}

/// The events that end a notification: messages read (nil: all of them) or deleted.
public enum ReadEvent: Sendable, Equatable {
    case read(Set<Int>?)
    case deleted(Set<Int>)

    /// The event's meaning, or nil for any other event.
    public init?(_ event: [String: Any]) {
        func ids(_ value: Any?) -> [Int] {
            (value as? [Any])?.compactMap(jsonInt) ?? []
        }
        switch event["type"] as? String {
        case "update_message_flags":
            // Servers before feature level 32 send "operation".
            let op = event.keys.contains("op") ? event["op"] : event["operation"]
            guard op as? String == "add", event["flag"] as? String == "read" else { return nil }
            self = .read(event.truthy("all") ? nil : Set(ids(event["messages"])))
        case "delete_message", "delete":
            var deleted = ids(event["message_ids"])
            if let id = event["message_id"].flatMap(jsonInt) {
                deleted.append(id)
            }
            self = .deleted(Set(deleted))
        default:
            return nil
        }
    }
}

private struct MessageKey: Hashable {
    var server: String
    var id: Int
}

private struct Batch {
    var handle: (any Cancellable)?
    var held: [Notification] = []
}

public actor Engine {
    private let output: any EngineOutput
    private let config: @Sendable () -> Config
    private let isPaused: @Sendable () -> Bool
    private let clock: @Sendable () -> Double
    private let scheduler: any Scheduler
    private let localMinutes: @Sendable () -> Int
    private let log: (@Sendable (String) -> Void)?

    private var lastSound: [SourceKey: Double] = [:]
    private var batches: [SourceKey: Batch] = [:]
    private var repeats: [MessageKey: any Cancellable] = [:]
    // Insertion order of repeats, so read handling cancels in Python's order.
    private var repeatOrder: [MessageKey] = []
    private var maxGap = 0.0
    /// Each joined topic's notifications not yet read.
    private var unread: [TopicKey: [Notification]] = [:]
    private var stopped = false

    public init(
        output: any EngineOutput,
        config: @escaping @Sendable () -> Config,
        isPaused: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        scheduler: any Scheduler = TaskScheduler(),
        localMinutes: @escaping @Sendable () -> Int = ZIrisCore.localMinutes,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.output = output
        self.config = config
        self.isPaused = isPaused
        self.clock = clock
        self.scheduler = scheduler
        self.localMinutes = localMinutes
        self.log = log
    }

    // MARK: public

    public func submit(_ notification: Notification) {
        if stopped || isPaused() {
            return
        }
        var acts: [@Sendable () -> Void] = []
        submit(notification, &acts)
        perform(acts)
    }

    /// Read and delete events: stop repeats and clear alerts for those messages.
    public func handle(server: String, _ event: ReadEvent) {
        let ids: Set<Int>?
        switch event {
        case .read(let read): ids = read
        case .deleted(let deleted): ids = deleted
        }
        forget(server: server, ids: ids)
        forgetConversations(server: server) { ids?.contains($0) ?? true }
        output.clearRead(server: server, ids: ids)
    }

    /// After a new event queue, catch up on reads missed while the old one was
    /// dead: stop repeats and clear sticky alerts for anything no longer
    /// unread. Clearing makes no noise, so it happens even while paused.
    public func reconcileUnread(server: String, unread: Set<Int>) {
        let held = batches.values.flatMap(\.held).filter { $0.message.server == server }.map(\.message.id)
        let known = Set(repeats.keys.filter { $0.server == server }.map(\.id)).union(held)
        forget(server: server, ids: known.subtracting(unread))
        forgetConversations(server: server) { !unread.contains($0) }
        output.clearUnlessUnread(server: server, unread: unread)
    }

    public func stop() {
        stopped = true
        for key in repeatOrder {
            repeats[key]?.cancel()
        }
        for batch in batches.values {
            batch.handle?.cancel()
        }
        repeats = [:]
        repeatOrder = []
        batches = [:]
        unread = [:]
    }

    // MARK: focus

    private func focusMode() -> String {
        let focus = config().focus
        if focus.mode != "off" {
            return focus.mode
        }
        if quietNow(focus.quietHours, minute: localMinutes()) {
            return focus.quietMode
        }
        return "off"
    }

    private enum FocusVerdict { case drop, silent, ok }

    private func verdict(_ notification: Notification) -> FocusVerdict {
        let mode = focusMode()
        if mode == "mentions_and_dms", !personal(notification) {
            return .drop
        }
        return mode == "silent" ? .silent : .ok
    }

    // MARK: submit

    private func submit(_ notification: Notification, _ acts: inout [@Sendable () -> Void]) {
        let action = notification.action
        let verdict = verdict(notification)
        if verdict == .drop {
            say(notification, "focus: dropped")
            return
        }
        let quiet = verdict == .silent
        let key = SourceKey(notification)
        let now = clock()

        // Past group_after unread, a joined topic's banner is its summary.
        // Conversations group this way instead of batching.
        var grouped: (TopicKey, [Notification])?
        if let conversation = notification.conversation {
            unread[conversation, default: []].append(notification)
            let held = unread[conversation]!
            if held.count > action.groupAfter {
                grouped = (conversation, held)
                say(notification, "conversation: summary of \(held.count)")
            }
        }
        let batching = action.batchWindow > 0 && notification.conversation == nil

        if batching, batches[key] != nil {
            batches[key]!.held.append(notification)
            say(notification, "batch: held")
            return
        }

        let gap = action.minGap > 0 && now - (lastSound[key] ?? -1e18) < Double(action.minGap)
        if quiet {
            say(notification, "focus silent: banner only")
        } else if gap {
            say(notification, "min_gap \(action.minGap)s: banner only")
        }

        let output = output
        if let (conversation, held) = grouped {
            if !(quiet || gap) {
                var copy = notification
                copy.action.banner = "off"
                let noBanner = copy
                acts.append { output.deliver(noBanner) }
                if audible(notification) {
                    rememberSound(key, now: now, gap: Double(action.minGap))
                }
            }
            acts.append { output.conversationSummary(conversation, held) }
        } else if quiet || gap {
            let bare = stripped(notification)
            acts.append { output.banner(bare) }
        } else {
            acts.append { output.deliver(notification) }
            if audible(notification) {
                rememberSound(key, now: now, gap: Double(action.minGap))
            }
        }

        if batching {
            var batch = Batch()
            batch.handle = scheduler.schedule(after: Double(action.batchWindow)) { [weak self] in
                await self?.flush(key)
            }
            batches[key] = batch
            say(notification, "batch: window \(action.batchWindow)s")
        }

        if !(quiet || gap), action.repeat > 0, audible(notification) {
            scheduleRepeat(notification, number: 1)
        }
    }

    // MARK: batching

    private func flush(_ key: SourceKey) {
        guard let batch = batches.removeValue(forKey: key), !batch.held.isEmpty, !isPaused() else {
            return
        }
        let latest = batch.held.last!
        if latest.action.banner == "off" {
            return
        }
        var heading = stripped(latest)
        heading.summary = summary(batch.held)
        heading.batch = batch.held.map(\.message)
        say(heading, "batch: summary \(pythonRepr(heading.summary))")
        output.banner(heading)
    }

    // MARK: repeats

    private func scheduleRepeat(_ notification: Notification, number: Int) {
        let key = MessageKey(server: notification.message.server, id: notification.message.id)
        if let previous = removeRepeat(key) {
            previous.cancel()
        }
        repeats[key] = scheduler.schedule(after: Double(notification.action.repeatEvery)) { [weak self] in
            await self?.repeatFired(notification, number: number)
        }
        repeatOrder.append(key)
    }

    private func removeRepeat(_ key: MessageKey) -> (any Cancellable)? {
        guard let handle = repeats.removeValue(forKey: key) else { return nil }
        repeatOrder.removeAll { $0 == key }
        return handle
    }

    private func repeatFired(_ notification: Notification, number: Int) {
        let key = MessageKey(server: notification.message.server, id: notification.message.id)
        if stopped || removeRepeat(key) == nil {
            return
        }
        if isPaused() || verdict(notification) != .ok {
            say(notification, "repeat: stopped")
            return
        }
        let action = notification.action
        // action.volume is already rule x server x master, so the boost is
        // scaled the same way and the ceiling is what server x master allows.
        let config = config()
        let server = config.servers.first { $0.name == notification.message.server }?.volume ?? 100
        let scale = Double(server * config.masterVolume)
        let ceiling = min(100, Int((scale / 100).rounded(.toNearestOrEven)))
        let boost = Int((Double(action.repeatBoost * number) * scale / 10000).rounded(.toNearestOrEven))
        let volume = min(ceiling, action.volume + boost)
        say(notification, "repeat \(number)/\(action.repeat) at \(volume)%")
        output.sound(notification, volume: volume)
        if number < action.repeat {
            scheduleRepeat(notification, number: number + 1)
        }
    }

    // MARK: read awareness

    private func forget(server: String, ids: Set<Int>?) {
        for key in repeatOrder where key.server == server && (ids?.contains(key.id) ?? true) {
            removeRepeat(key)?.cancel()
        }
        for key in batches.keys {
            batches[key]!.held.removeAll { $0.message.server == server && (ids?.contains($0.message.id) ?? true) }
        }
    }

    /// Drop read messages from joined topics; a topic left with none has its
    /// summary cleared, and its next message is a single alert again.
    private func forgetConversations(server: String, read: (Int) -> Bool) {
        for (key, held) in unread where key.server == server {
            let left = held.filter { !read($0.message.id) }
            if left.isEmpty {
                unread[key] = nil
                output.clearConversation(key)
            } else {
                unread[key] = left
            }
        }
    }

    // MARK: helpers

    /// Record a sound, and forget entries older than any gap seen.
    private func rememberSound(_ key: SourceKey, now: Double, gap: Double) {
        maxGap = max(maxGap, gap)
        lastSound[key] = now
        if lastSound.count > 1 {
            lastSound = lastSound.filter { $0.key == key || now - $0.value < maxGap }
        }
    }

    private func perform(_ acts: [@Sendable () -> Void]) {
        for act in acts {
            act()
        }
    }

    private func say(_ notification: Notification, _ text: String) {
        log?("\(notification.message.server) #\(notification.message.id): \(text)")
    }
}

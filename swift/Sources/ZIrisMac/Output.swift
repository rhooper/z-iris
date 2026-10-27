import Foundation
import ZIrisCore
import ZulipKit

// Where the engine's decisions go (output.py's RealOutput and DryRunOutput).
// Sound and flash happen at once; banners (with their image fetches) and
// clears run in order on one worker, so a slow avatar never delays a sound
// and a clear never overtakes the alert it clears.

/// The work's result, or nil when it takes longer than seconds.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// One task that runs jobs in submission order, with a bounded backlog.
final class BannerWorker: @unchecked Sendable {
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let lock = NSLock()
    private var pending = 0
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = limit
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.continuation = continuation
        Task.detached { [weak self] in
            for await job in stream {
                await job()
                self?.lock.withLock { self?.pending -= 1 }
            }
        }
    }

    /// False when the backlog is full and the job was dropped.
    @discardableResult
    func submit(_ job: @escaping @Sendable () async -> Void) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard pending < limit else { return false }
            pending += 1
            return true
        }
        if accepted { continuation.yield(job) }
        return accepted
    }

    /// Wait until every job submitted so far has run.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if !submit({ done.resume() }) { done.resume() }
        }
    }
}

public final class RealOutput: EngineOutput, @unchecked Sendable {
    private let config: @Sendable () -> Config
    private let notifier: any Notifying
    private let priority: PriorityLink?
    private let images: (@Sendable (Message) async -> MessageImages)?
    private let player: SoundPlayer
    private let flasher: Flasher?
    private let summarizer: (any Summarizer)?
    private let summaryTimeout: Double
    private let worker = BannerWorker()

    /// - Parameters:
    ///   - priority: sticky alerts; nil without z-iris priority.
    ///   - images: the avatar and the message's picture for a banner.
    public init(
        config: @escaping @Sendable () -> Config, notifier: any Notifying, priority: PriorityLink?,
        images: (@Sendable (Message) async -> MessageImages)?, player: SoundPlayer, flasher: Flasher?,
        summarizer: (any Summarizer)? = nil, summaryTimeout: Double = 10
    ) {
        self.summarizer = summarizer
        self.summaryTimeout = summaryTimeout
        self.config = config
        self.notifier = notifier
        self.priority = priority
        self.images = images
        self.player = player
        self.flasher = flasher
    }

    public func deliver(_ notification: ZIrisCore.Notification) {
        // The banner last: a slow avatar fetch must not delay the sound or flash.
        sound(notification, volume: nil)
        flash(notification)
        banner(notification)
    }

    public func sound(_ notification: ZIrisCore.Notification, volume: Int?) {
        let action = notification.action
        let level = volume ?? action.volume
        if action.sound != "none", level > 0 {
            player.play(action.sound, volume: level)
        }
    }

    public func flash(_ notification: ZIrisCore.Notification) {
        let action = notification.action
        if action.flash != "none" {
            flasher?.flash(mode: action.flash, color: action.flashColor, seconds: action.flashSeconds)
        }
    }

    /// Returns at once; the image lookup and the notifier call run on the worker.
    public func banner(_ notification: ZIrisCore.Notification) {
        guard notification.action.banner != "off" else { return }
        if !worker.submit({ [self] in await show(notification) }) {
            logProblem("banner queue full; banner dropped")
        }
    }

    private func show(_ notification: ZIrisCore.Notification) async {
        let action = notification.action
        let message = notification.message
        let titleOnly = action.banner == "title"
        let title = notificationTitle(notification)
        var image: String?
        var sender: Sender?
        if let images {
            let found = await images(message)
            let picture = titleOnly ? nil : found.picture
            image = titleOnly ? nil : picture ?? found.avatar
            if notification.summary == nil {  // a summary has no single sender
                sender = senderFor(message, title: title, images: MessageImages(avatar: found.avatar, picture: picture))
            }
        }
        // Sticky stays until read; stay= for that many seconds; both need z-iris priority.
        let persistent = (action.sticky || action.stay > 0) ? priority : nil
        let group = notification.group ?? bannerGroup(message)
        let target: any Notifying = persistent ?? notifier
        await target.show(
            title: title, body: notificationBody(notification), url: notification.url, image: image, group: group, sender: sender
        )
        if notification.summary != nil, action.summarize, action.banner == "full", let summarizer, !notification.batch.isEmpty {
            // The model's sentence replaces the body in place (same id), if it
            // answers in time; otherwise the plain summary stays.
            let batch = notification.batch, url = notification.url, timeout = summaryTimeout, picture = image
            Task.detached { [worker] in
                guard let text = await withTimeout(timeout, { await summarizer.summarize(batch) }) else { return }
                worker.submit {
                    await target.show(title: title, body: text, url: url, image: picture, group: group, sender: nil)
                }
            }
        }
        if let persistent, !action.sticky {
            let seconds = action.stay
            Task.detached { [worker] in
                try? await Task.sleep(for: .seconds(seconds))
                worker.submit { persistent.clearGroups([group]) }
            }
        }
    }

    /// Remove sticky alerts for messages read (or deleted) elsewhere, by
    /// group, even for alerts this run never showed.
    public func clearRead(server: String, ids: Set<Int>?) {
        guard let priority else { return }
        guard let ids else {
            worker.submit { priority.clearServer(server, keep: []) }
            return
        }
        // One job per event: marking a channel read can list thousands of ids.
        let groups = ids.sorted().map { groupID(server: server, id: $0) }
        if !worker.submit({ priority.clearGroups(groups) }) {
            logProblem("banner queue full; sticky alerts not cleared")
        }
    }

    public func clearUnlessUnread(server: String, unread: Set<Int>) {
        guard let priority else { return }
        worker.submit { priority.clearServer(server, keep: unread) }
    }

    /// Wait until every banner submitted so far has been shown.
    public func drain() async {
        await worker.drain()
    }
}

/// Prints what would happen instead of doing it (`--dry-run`).
public final class DryRunOutput: EngineOutput {
    private let player: [String]
    private let write: @Sendable (String) -> Void

    public init(player: [String], write: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.player = player
        self.write = write
    }

    public func deliver(_ notification: ZIrisCore.Notification) { write(dryRunText(notification, player: player)) }
    public func banner(_ notification: ZIrisCore.Notification) { deliver(notification) }
    public func sound(_ notification: ZIrisCore.Notification, volume: Int?) {}
    public func clearRead(server: String, ids: Set<Int>?) { write(dryRunClearText(server: server, ids: ids)) }
    public func clearUnlessUnread(server: String, unread: Set<Int>) {
        write(dryRunClearUnlessText(server: server, unread: unread))
    }
}

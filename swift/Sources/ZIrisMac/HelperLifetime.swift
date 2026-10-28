import Darwin

/// When z-iris priority should quit. Started by z-iris, it goes the moment
/// z-iris does (quit, crash or kill); launched by macOS only to deliver a
/// click on an alert (its parent is launchd), it lingers to handle it.
public struct HelperLifetime: Sendable {
    public let parent: pid_t

    public init(parent: pid_t = getppid()) {
        self.parent = parent
    }

    /// Started by z-iris rather than by launchd.
    public var hasParent: Bool { parent > 1 }

    /// The parent is gone: launchd has adopted the helper.
    public func orphaned(currentParent: pid_t = getppid()) -> Bool {
        hasParent && currentParent != parent
    }

    /// Seconds to stay after the input ends: none when z-iris has gone,
    /// time for the click when macOS launched it.
    public var graceAfterInput: Double { hasParent ? 0 : 30 }
}

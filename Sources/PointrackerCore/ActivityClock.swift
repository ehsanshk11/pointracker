import Foundation

/// Last keyboard and mouse activity, shared between the main thread (which
/// records input) and the camera queue (which throttles frame processing).
public final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var mouse: TimeInterval?
    private var key: TimeInterval?
    public let mouseHold: TimeInterval
    public let typingHold: TimeInterval

    public init(mouseHold: TimeInterval, typingHold: TimeInterval) {
        self.mouseHold = mouseHold
        self.typingHold = typingHold
    }

    public func noteMouse(at time: TimeInterval) {
        lock.lock()
        mouse = time
        lock.unlock()
    }

    public func noteKey(at time: TimeInterval) {
        lock.lock()
        key = time
        lock.unlock()
    }

    public var lastMouse: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return mouse
    }

    public var lastKey: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    /// Frames are only needed at full rate when a switch could happen. While
    /// the user types or uses the mouse, a slow trickle is enough to keep a
    /// recent sample around for learning from clicks.
    public func frameInterval(at time: TimeInterval, activeFPS: Double, heldFPS: Double) -> TimeInterval {
        lock.lock()
        let lastMouse = mouse
        let lastKey = key
        lock.unlock()
        let held = FocusDecider.holdReason(
            at: time,
            lastMouse: lastMouse,
            lastKey: lastKey,
            mouseHold: mouseHold,
            typingHold: typingHold
        ) != nil
        return 1 / (held ? heldFPS : activeFPS)
    }
}

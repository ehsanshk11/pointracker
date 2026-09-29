import Foundation

/// Last keyboard and mouse activity, shared between the main thread (which
/// records input) and the camera queue (which slows analysis while held).
public final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var mouse: TimeInterval?
    private var key: TimeInterval?
    private var mouseHold: TimeInterval
    private var typingHold: TimeInterval

    public init(mouseHold: TimeInterval, typingHold: TimeInterval) {
        self.mouseHold = mouseHold
        self.typingHold = typingHold
    }

    public func setHolds(mouse: TimeInterval, typing: TimeInterval) {
        lock.lock()
        mouseHold = mouse
        typingHold = typing
        lock.unlock()
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

    /// True while no focus switch may fire because the user is busy.
    public func isHeld(at time: TimeInterval) -> Bool {
        lock.lock()
        let lastMouse = mouse
        let lastKey = key
        let mouseHold = self.mouseHold
        let typingHold = self.typingHold
        lock.unlock()
        return FocusDecider.holdReason(
            at: time,
            lastMouse: lastMouse,
            lastKey: lastKey,
            mouseHold: mouseHold,
            typingHold: typingHold
        ) != nil
    }
}

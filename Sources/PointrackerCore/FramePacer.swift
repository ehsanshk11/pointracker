import Foundation

/// Decides how often camera frames are analysed. Vision is the dominant CPU
/// cost, and most of the time the head is still and facing the focused
/// screen, so full rate is only used while something is happening.
///
/// - active:  the head just moved, or a switch is being timed
/// - settled: face visible and still
/// - held:    the user is typing or using the mouse (no switch can fire)
/// - absent:  no face for a while (user away)
///
/// Thread-safe: the camera queue reads and observes, the main thread keeps
/// it active while a switch is pending.
public final class FramePacer: @unchecked Sendable {
    public struct Rates: Equatable, Sendable {
        public var active: Double = 15
        public var settled: Double = 7.5
        public var held: Double = 5
        public var absent: Double = 2

        public init() {}
    }

    public let rates: Rates
    /// Head movement (degrees) that counts as "something is happening".
    public let motionThreshold: Double
    /// How long full rate lasts after movement.
    public let activeWindow: TimeInterval

    private let lock = NSLock()
    private var referenceYaw: Double?
    private var referencePitch: Double?
    private var hadFace = false
    private var activeUntil: TimeInterval = -.infinity

    public init(rates: Rates = Rates(), motionThreshold: Double = 2.5, activeWindow: TimeInterval = 1.0) {
        self.rates = rates
        self.motionThreshold = motionThreshold
        self.activeWindow = activeWindow
    }

    /// Feed every analysed frame (nil = no face).
    public func observe(_ sample: FaceSample?, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if let sample {
            if let yaw = referenceYaw, let pitch = referencePitch,
               abs(sample.yaw - yaw) < motionThreshold, abs(sample.pitch - pitch) < motionThreshold {
                // Still: keep the old reference so slow drift adds up to motion.
            } else {
                referenceYaw = sample.yaw
                referencePitch = sample.pitch
                activeUntil = max(activeUntil, time + activeWindow)
            }
        } else if hadFace {
            // Face just vanished, e.g. turning far away from the camera.
            referenceYaw = nil
            referencePitch = nil
            activeUntil = max(activeUntil, time + activeWindow)
        }
        hadFace = sample != nil
    }

    public func keepActive(until time: TimeInterval) {
        lock.lock()
        activeUntil = max(activeUntil, time)
        lock.unlock()
    }

    public func interval(at time: TimeInterval, held: Bool) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if held { return 1 / rates.held }
        if time < activeUntil { return 1 / rates.active }
        return 1 / (hadFace ? rates.settled : rates.absent)
    }
}

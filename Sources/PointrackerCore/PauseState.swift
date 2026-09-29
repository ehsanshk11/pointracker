import Foundation

/// Why tracking is not running. Several can hold at once; the camera runs
/// only when none do.
public enum PauseReason: String, CaseIterable, Sendable {
    // Declared in display priority order.
    case noCamera
    case noAccessibility
    case systemAsleep
    case screenLocked
    case displaysAsleep
    case onBattery
    case user
    case singleScreen
    case notCalibrated

    public var message: String {
        switch self {
        case .noCamera: return "Paused — camera access needed"
        case .noAccessibility: return "Paused — Accessibility permission needed"
        case .systemAsleep: return "Paused — Mac is asleep"
        case .screenLocked: return "Paused — screen is locked"
        case .displaysAsleep: return "Paused — displays are asleep"
        case .onBattery: return "Paused — running on battery"
        case .user: return "Paused (⇧⌘G to resume)"
        case .singleScreen: return "Paused — needs two or more displays"
        case .notCalibrated: return "Not calibrated — choose Calibrate…"
        }
    }
}

public struct PauseState: Equatable, Sendable {
    public private(set) var reasons: Set<PauseReason> = []

    public init() {}

    /// Returns true when the set of reasons changed.
    @discardableResult
    public mutating func set(_ reason: PauseReason, _ active: Bool) -> Bool {
        if active {
            return reasons.insert(reason).inserted
        }
        return reasons.remove(reason) != nil
    }

    public var isPaused: Bool { !reasons.isEmpty }

    public var primaryReason: PauseReason? {
        PauseReason.allCases.first(where: reasons.contains)
    }

    /// Calibration is an explicit user action, so it may run the camera even
    /// when paused by the user, on battery, or before Accessibility is granted.
    public func cameraShouldRun(calibrating: Bool) -> Bool {
        if calibrating {
            return reasons.isSubset(of: [.user, .onBattery, .notCalibrated, .noAccessibility])
        }
        return reasons.isEmpty
    }
}

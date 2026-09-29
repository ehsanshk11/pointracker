import Foundation

public struct DeciderConfig: Equatable, Sendable {
    /// How long the user must keep facing another screen before focus moves.
    public var dwell: TimeInterval = 0.30
    /// Minimum time between two switches.
    public var cooldown: TimeInterval = 0.40
    /// No switching while the mouse/trackpad is in use and this long after.
    public var mouseHold: TimeInterval = 1.5
    /// No switching while typing and this long after the last key.
    public var typingHold: TimeInterval = 0.6
    /// How much a challenger must out-score the current screen.
    public var stickiness: Double = 0.2
    /// Minimum score for a challenger to be considered at all.
    public var minScore: Double = 0.6
    /// How long a lost face may keep a pending switch alive.
    public var faceLossGrace: TimeInterval = 0.6

    public init() {}
}

/// User-facing presets trading responsiveness against accidental switches.
public enum SwitchSpeed: String, CaseIterable, Sendable {
    case fast
    case normal
    case relaxed

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .relaxed: return "Relaxed"
        }
    }

    public var config: DeciderConfig {
        var config = DeciderConfig()
        switch self {
        case .fast:
            config.dwell = 0.15
            config.cooldown = 0.3
            config.mouseHold = 0.8
            config.typingHold = 0.4
        case .normal:
            break
        case .relaxed:
            config.dwell = 0.5
            config.cooldown = 0.6
            config.mouseHold = 2.0
            config.typingHold = 0.8
        }
        return config
    }
}

public struct DeciderInput: Sendable {
    public var time: TimeInterval
    /// Nil when no face was found in the frame.
    public var classification: Classification?
    /// The screen that currently has keyboard focus, if known.
    public var currentScreen: ScreenID?
    public var lastMouseActivity: TimeInterval?
    public var lastKeyActivity: TimeInterval?

    public init(
        time: TimeInterval,
        classification: Classification?,
        currentScreen: ScreenID?,
        lastMouseActivity: TimeInterval? = nil,
        lastKeyActivity: TimeInterval? = nil
    ) {
        self.time = time
        self.classification = classification
        self.currentScreen = currentScreen
        self.lastMouseActivity = lastMouseActivity
        self.lastKeyActivity = lastKeyActivity
    }
}

public enum HoldReason: Equatable, Sendable {
    case mouse
    case typing
}

public enum DeciderOutput: Equatable, Sendable {
    case idle
    case holding(HoldReason)
    /// A challenger is being timed; progress runs 0...1 over the dwell.
    case tracking(ScreenID, progress: Double)
    case switchTo(ScreenID)
}

/// Turns a stream of per-frame classifications into focus switches.
///
/// A switch needs the same challenger to win continuously for `dwell`, with a
/// clear lead over the current screen. Any interruption restarts the clock, so
/// two quick glances never add up to a switch. Nothing happens while the user
/// types or uses the mouse.
public struct FocusDecider: Sendable {
    public var config: DeciderConfig
    public private(set) var candidate: ScreenID?
    private var candidateSince: TimeInterval = 0
    private var candidateLastSeen: TimeInterval = 0
    private var lastFaceSeen: TimeInterval?
    private var lastSwitchTime: TimeInterval = -.infinity
    private var lastSwitchTarget: ScreenID?

    public init(config: DeciderConfig = DeciderConfig()) {
        self.config = config
    }

    public mutating func reset() {
        candidate = nil
        lastFaceSeen = nil
    }

    public static func holdReason(
        at time: TimeInterval,
        lastMouse: TimeInterval?,
        lastKey: TimeInterval?,
        mouseHold: TimeInterval,
        typingHold: TimeInterval
    ) -> HoldReason? {
        if let lastMouse, time - lastMouse < mouseHold { return .mouse }
        if let lastKey, time - lastKey < typingHold { return .typing }
        return nil
    }

    public mutating func step(_ input: DeciderInput) -> DeciderOutput {
        let t = input.time
        let hold = Self.holdReason(
            at: t,
            lastMouse: input.lastMouseActivity,
            lastKey: input.lastKeyActivity,
            mouseHold: config.mouseHold,
            typingHold: config.typingHold
        )

        // Right after a switch the caller may not have caught up yet; trust
        // our own switch over a stale "current screen".
        let inCooldown = t - lastSwitchTime < config.cooldown
        let current = inCooldown ? (lastSwitchTarget ?? input.currentScreen) : input.currentScreen

        guard let classification = input.classification else {
            return faceLost(at: t, current: current, hold: hold)
        }
        lastFaceSeen = t

        if classification.isOutlier {
            candidate = nil
            return hold.map(DeciderOutput.holding) ?? .idle
        }
        guard let target = chooseTarget(classification, current: current), target != current else {
            candidate = nil
            return hold.map(DeciderOutput.holding) ?? .idle
        }
        if target != candidate {
            candidate = target
            candidateSince = t
        }
        candidateLastSeen = t
        // While typing or using the mouse the dwell clock keeps running but
        // never fires, so a user already facing the other screen gets focus
        // the moment the hold ends instead of waiting a full dwell more.
        if let hold {
            return .holding(hold)
        }
        return fireIfReady(target, at: t)
    }

    /// Turning far toward a screen can take the face out of the camera's
    /// view (e.g. a camera off to one side). If the challenger had already
    /// been seen for half the dwell, let the clock keep running briefly.
    private mutating func faceLost(at t: TimeInterval, current: ScreenID?, hold: HoldReason?) -> DeciderOutput {
        let idle = hold.map(DeciderOutput.holding) ?? .idle
        guard let target = candidate, target != current else {
            candidate = nil
            return idle
        }
        if let seen = lastFaceSeen, t - seen > config.faceLossGrace {
            candidate = nil
            return idle
        }
        if let hold {
            return .holding(hold)
        }
        if candidateLastSeen - candidateSince >= config.dwell / 2 {
            return fireIfReady(target, at: t)
        }
        return .tracking(target, progress: progress(at: t))
    }

    private func chooseTarget(_ classification: Classification, current: ScreenID?) -> ScreenID? {
        guard let best = classification.best else { return nil }
        guard let current, best != current else { return best }
        let bestScore = classification.score(for: best)
        let lead = bestScore - classification.score(for: current)
        if bestScore >= config.minScore && lead >= config.stickiness {
            return best
        }
        return current
    }

    private func progress(at t: TimeInterval) -> Double {
        min(1, max(0, (t - candidateSince) / max(config.dwell, 0.001)))
    }

    private mutating func fireIfReady(_ target: ScreenID, at t: TimeInterval) -> DeciderOutput {
        if t - candidateSince >= config.dwell && t - lastSwitchTime >= config.cooldown {
            lastSwitchTime = t
            lastSwitchTarget = target
            candidate = nil
            return .switchTo(target)
        }
        return .tracking(target, progress: progress(at: t))
    }
}

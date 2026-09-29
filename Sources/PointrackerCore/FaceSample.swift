import Foundation

/// Identifies a display in a way that survives reboots and reconnects
/// (vendor/model/serial rather than the volatile CGDirectDisplayID).
public struct ScreenID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// One observation of the user's head from a single camera frame.
///
/// Angles are in degrees and relative to the camera, not to any screen: the
/// camera can sit anywhere (e.g. on a laptop off to one side) because
/// calibration learns what each screen looks like from where the camera is.
public struct FaceSample: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Face centre in the camera frame, 0...1. Captures sitting off to one side.
    public var faceX: Double
    public var faceY: Double
    /// Face width as a fraction of the frame. Captures sitting closer or farther.
    public var faceSize: Double
    /// Nose position across the face, roughly -0.5...0.5. A geometric head-turn
    /// cue that complements Vision's yaw. Nil when landmarks were unavailable.
    public var noseOffset: Double?
    /// Pupil position inside the eye, roughly -1...1. Nil when unavailable.
    public var eyeOffset: Double?
    /// Monotonic time (seconds since boot) the frame was processed.
    public var timestamp: TimeInterval

    public init(
        yaw: Double,
        pitch: Double,
        roll: Double = 0,
        faceX: Double = 0.5,
        faceY: Double = 0.5,
        faceSize: Double = 0.25,
        noseOffset: Double? = nil,
        eyeOffset: Double? = nil,
        timestamp: TimeInterval = 0
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.faceX = faceX
        self.faceY = faceY
        self.faceSize = faceSize
        self.noseOffset = noseOffset
        self.eyeOffset = eyeOffset
        self.timestamp = timestamp
    }
}

/// How far apart two face samples are, in "calibration units": 1.0 is roughly
/// an 8° head turn. Head yaw dominates; position and size let the model tell
/// apart the same head angle seen from a different seat.
public struct FeatureSpace: Codable, Equatable, Sendable {
    public var yawScale: Double = 8
    public var pitchScale: Double = 8
    public var positionScale: Double = 0.1
    public var sizeScale: Double = 0.05
    public var noseScale: Double = 0.06
    public var eyeScale: Double = 0.3

    public var yawWeight: Double = 1
    public var pitchWeight: Double = 0.7
    public var positionWeight: Double = 0.4
    public var sizeWeight: Double = 0.3
    public var noseWeight: Double = 0.5
    public var eyeWeight: Double = 0.3

    public init() {}

    public func distance(_ a: FaceSample, _ b: FaceSample) -> Double {
        var sum = 0.0
        func add(_ delta: Double, _ scale: Double, _ weight: Double) {
            let d = delta / scale
            sum += weight * d * d
        }
        add(a.yaw - b.yaw, yawScale, yawWeight)
        add(a.pitch - b.pitch, pitchScale, pitchWeight)
        add(a.faceX - b.faceX, positionScale, positionWeight)
        add(a.faceY - b.faceY, positionScale, positionWeight)
        add(a.faceSize - b.faceSize, sizeScale, sizeWeight)
        if let na = a.noseOffset, let nb = b.noseOffset {
            add(na - nb, noseScale, noseWeight)
        }
        if let ea = a.eyeOffset, let eb = b.eyeOffset {
            add(ea - eb, eyeScale, eyeWeight)
        }
        return sum.squareRoot()
    }
}

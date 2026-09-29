import Foundation

/// A face sample tagged with the screen the user was looking at.
public struct LabeledSample: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Collected while the user followed the calibration dots.
        case calibration
        /// Collected when the user clicked: people look where they click.
        case click
    }

    public var screen: ScreenID
    public var sample: FaceSample
    public var source: Source

    public init(screen: ScreenID, sample: FaceSample, source: Source) {
        self.screen = screen
        self.sample = sample
        self.source = source
    }
}

/// Training data for the classifier. Holds a bounded number of samples per
/// screen; when full, the oldest click samples go first so everyday use keeps
/// the model current while calibration anchors stay put.
public struct SampleStore: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public private(set) var samples: [LabeledSample]
    public var maxPerScreen: Int

    public init(maxPerScreen: Int = 150) {
        self.version = Self.currentVersion
        self.samples = []
        self.maxPerScreen = maxPerScreen
    }

    public var screens: Set<ScreenID> { Set(samples.map(\.screen)) }

    public func samples(for screen: ScreenID) -> [LabeledSample] {
        samples.filter { $0.screen == screen }
    }

    public func count(for screen: ScreenID, source: LabeledSample.Source? = nil) -> Int {
        samples.reduce(0) { count, labeled in
            guard labeled.screen == screen, source == nil || labeled.source == source else { return count }
            return count + 1
        }
    }

    public mutating func add(_ labeled: LabeledSample) {
        samples.append(labeled)
        trim(labeled.screen)
    }

    /// Replaces everything known about a screen, e.g. after recalibrating it.
    /// Old click samples go too: they were learned from the old seating.
    public mutating func resetScreen(_ screen: ScreenID, with newSamples: [LabeledSample]) {
        samples.removeAll { $0.screen == screen }
        samples.append(contentsOf: newSamples.filter { $0.screen == screen })
        trim(screen)
    }

    public mutating func removeAll() {
        samples.removeAll()
    }

    private mutating func trim(_ screen: ScreenID) {
        while count(for: screen) > maxPerScreen {
            if let index = samples.firstIndex(where: { $0.screen == screen && $0.source == .click }) {
                samples.remove(at: index)
            } else if let index = samples.firstIndex(where: { $0.screen == screen }) {
                samples.remove(at: index)
            } else {
                break
            }
        }
    }
}

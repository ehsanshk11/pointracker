import Foundation

/// Which screen a face sample most likely faces.
public struct Classification: Equatable, Sendable {
    /// Probability-like scores per screen, summing to 1.
    public var scores: [ScreenID: Double]
    /// Distance to the closest training sample, in calibration units.
    public var nearestDistance: Double
    /// True when the pose is far from every screen (looking at a phone, the
    /// gap between monitors, out the window...). Never switch on these.
    public var isOutlier: Bool

    public init(scores: [ScreenID: Double], nearestDistance: Double, isOutlier: Bool) {
        self.scores = scores
        self.nearestDistance = nearestDistance
        self.isOutlier = isOutlier
    }

    public var best: ScreenID? {
        var result: (id: ScreenID, score: Double)?
        for (id, score) in scores {
            if let current = result,
               score < current.score || (score == current.score && id.rawValue >= current.id.rawValue) {
                continue
            }
            result = (id, score)
        }
        return result?.id
    }

    public func score(for screen: ScreenID?) -> Double {
        guard let screen else { return 0 }
        return scores[screen] ?? 0
    }
}

/// Gaussian-weighted k-nearest-neighbours over the calibration and click
/// samples. Simple, needs no training step, and adapts instantly as click
/// samples arrive.
public struct ScreenClassifier: Sendable {
    public var space = FeatureSpace()
    public var neighbors = 9
    public var bandwidth = 1.0
    public var outlierDistance = 3.5

    public init() {}

    public func classify(
        _ sample: FaceSample,
        in store: SampleStore,
        among screens: Set<ScreenID>? = nil
    ) -> Classification? {
        var distances: [(distance: Double, screen: ScreenID)] = []
        distances.reserveCapacity(store.samples.count)
        for labeled in store.samples where screens?.contains(labeled.screen) ?? true {
            distances.append((space.distance(sample, labeled.sample), labeled.screen))
        }
        guard !distances.isEmpty else { return nil }
        distances.sort { $0.distance < $1.distance }

        let nearest = distances[0].distance
        var scores: [ScreenID: Double] = [:]
        for (distance, screen) in distances.prefix(max(1, neighbors)) {
            scores[screen, default: 0] += exp(-(distance * distance) / (2 * bandwidth * bandwidth))
        }
        let total = scores.values.reduce(0, +)
        if total > 1e-12 {
            scores = scores.mapValues { $0 / total }
        } else {
            scores = [distances[0].screen: 1]
        }
        return Classification(scores: scores, nearestDistance: nearest, isOutlier: nearest > outlierDistance)
    }
}

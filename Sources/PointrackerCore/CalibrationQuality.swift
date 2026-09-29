import Foundation

/// How well two screens can be told apart from where the camera sits.
public struct ScreenSeparation: Equatable, Sendable {
    public enum Rating: String, Sendable {
        case good, fair, poor
    }

    public var first: ScreenID
    public var second: ScreenID
    /// Smallest distance between any sample of one screen and any of the
    /// other: how close the nearest edges of the two screens look.
    public var closest: Double
    public var centroidDistance: Double

    public var rating: Rating {
        if closest >= 1.0 { return .good }
        if closest >= 0.5 { return .fair }
        return .poor
    }
}

public enum CalibrationQuality {
    /// Per-feature median of a screen's samples.
    public static func centroid(of screen: ScreenID, in store: SampleStore) -> FaceSample? {
        let samples = store.samples(for: screen).map(\.sample)
        guard !samples.isEmpty else { return nil }
        return FaceSample(
            yaw: median(samples.map(\.yaw))!,
            pitch: median(samples.map(\.pitch))!,
            roll: median(samples.map(\.roll))!,
            faceX: median(samples.map(\.faceX))!,
            faceY: median(samples.map(\.faceY))!,
            faceSize: median(samples.map(\.faceSize))!,
            noseOffset: median(samples.compactMap(\.noseOffset)),
            eyeOffset: median(samples.compactMap(\.eyeOffset))
        )
    }

    public static func separations(
        in store: SampleStore,
        among screens: Set<ScreenID>? = nil,
        space: FeatureSpace = FeatureSpace()
    ) -> [ScreenSeparation] {
        let ids = (screens ?? store.screens).sorted { $0.rawValue < $1.rawValue }
        var result: [ScreenSeparation] = []
        for i in ids.indices {
            for j in ids.indices where j > i {
                let a = store.samples(for: ids[i]).map(\.sample)
                let b = store.samples(for: ids[j]).map(\.sample)
                guard !a.isEmpty, !b.isEmpty,
                      let ca = centroid(of: ids[i], in: store),
                      let cb = centroid(of: ids[j], in: store) else { continue }
                var closest = Double.infinity
                for x in a {
                    for y in b {
                        closest = min(closest, space.distance(x, y))
                    }
                }
                result.append(ScreenSeparation(
                    first: ids[i],
                    second: ids[j],
                    closest: closest,
                    centroidDistance: space.distance(ca, cb)
                ))
            }
        }
        return result
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

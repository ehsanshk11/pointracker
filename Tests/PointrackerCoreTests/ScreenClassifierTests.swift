import XCTest
@testable import PointrackerCore

/// Models a desk where the only camera is on a laptop to the user's left,
/// angled toward them: facing the laptop reads ~0° yaw, facing the external
/// monitor straight ahead reads ~35°, spreading ±12° across its width.
enum SideCameraDesk {
    static let laptop: ScreenID = "laptop"
    static let monitor: ScreenID = "monitor"

    static func store() -> SampleStore {
        var store = SampleStore()
        for i in 0..<30 {
            let jitter = Double(i % 5) - 2
            store.add(LabeledSample(
                screen: laptop,
                sample: FaceSample(yaw: jitter, pitch: -8 + jitter / 2),
                source: .calibration
            ))
            store.add(LabeledSample(
                screen: monitor,
                sample: FaceSample(yaw: 35 + Double(i % 7 - 3) * 4, pitch: jitter / 2),
                source: .calibration
            ))
        }
        return store
    }
}

final class ScreenClassifierTests: XCTestCase {
    let classifier = ScreenClassifier()

    func testClassifiesEachScreenFromSideCamera() throws {
        let store = SideCameraDesk.store()

        let monitor = try XCTUnwrap(classifier.classify(FaceSample(yaw: 33, pitch: 0), in: store))
        XCTAssertEqual(monitor.best, SideCameraDesk.monitor)
        XCTAssertGreaterThan(monitor.score(for: SideCameraDesk.monitor), 0.9)
        XCTAssertFalse(monitor.isOutlier)

        let laptop = try XCTUnwrap(classifier.classify(FaceSample(yaw: 1, pitch: -8), in: store))
        XCTAssertEqual(laptop.best, SideCameraDesk.laptop)
        XCTAssertGreaterThan(laptop.score(for: SideCameraDesk.laptop), 0.9)
    }

    func testFarRightEdgeOfMonitorStillMapsToMonitor() throws {
        let store = SideCameraDesk.store()
        let result = try XCTUnwrap(classifier.classify(FaceSample(yaw: 50, pitch: 0), in: store))
        XCTAssertEqual(result.best, SideCameraDesk.monitor)
        XCTAssertFalse(result.isOutlier)
    }

    func testPoseFarFromEveryScreenIsOutlier() throws {
        let store = SideCameraDesk.store()
        let result = try XCTUnwrap(classifier.classify(FaceSample(yaw: 120, pitch: 0), in: store))
        XCTAssertTrue(result.isOutlier)
    }

    func testCanRestrictToSubsetOfScreens() throws {
        let store = SideCameraDesk.store()
        let result = try XCTUnwrap(classifier.classify(
            FaceSample(yaw: 33, pitch: 0),
            in: store,
            among: [SideCameraDesk.laptop]
        ))
        XCTAssertEqual(result.best, SideCameraDesk.laptop)
        XCTAssertEqual(result.scores.count, 1)
    }

    func testEmptyStoreGivesNoClassification() {
        XCTAssertNil(classifier.classify(FaceSample(yaw: 0, pitch: 0), in: SampleStore()))
    }

    func testClickSamplesShiftTheBoundary() throws {
        var store = SideCameraDesk.store()
        let ambiguous = FaceSample(yaw: 16, pitch: -4)
        let before = try XCTUnwrap(classifier.classify(ambiguous, in: store))
        for _ in 0..<12 {
            store.add(LabeledSample(screen: SideCameraDesk.laptop, sample: ambiguous, source: .click))
        }
        let after = try XCTUnwrap(classifier.classify(ambiguous, in: store))
        XCTAssertEqual(after.best, SideCameraDesk.laptop)
        XCTAssertGreaterThan(after.score(for: SideCameraDesk.laptop), before.score(for: SideCameraDesk.laptop))
    }

    func testTiesBreakDeterministically() {
        let classification = Classification(scores: ["b": 0.5, "a": 0.5], nearestDistance: 0, isOutlier: false)
        XCTAssertEqual(classification.best, "a")
    }

    func testCalibrationQualityRatesSideCameraDeskGood() throws {
        let separations = CalibrationQuality.separations(in: SideCameraDesk.store())
        let separation = try XCTUnwrap(separations.first)
        XCTAssertEqual(separations.count, 1)
        XCTAssertEqual(separation.rating, .good)

        let monitor = try XCTUnwrap(CalibrationQuality.centroid(of: SideCameraDesk.monitor, in: SideCameraDesk.store()))
        XCTAssertEqual(monitor.yaw, 35, accuracy: 0.001)
    }

    func testCalibrationQualityFlagsOverlappingScreens() throws {
        var store = SampleStore()
        for i in 0..<10 {
            store.add(LabeledSample(screen: "a", sample: FaceSample(yaw: Double(i), pitch: 0), source: .calibration))
            store.add(LabeledSample(screen: "b", sample: FaceSample(yaw: Double(i) + 1, pitch: 0), source: .calibration))
        }
        let separation = try XCTUnwrap(CalibrationQuality.separations(in: store).first)
        XCTAssertEqual(separation.rating, .poor)
    }
}

import XCTest
@testable import PointrackerCore

final class PauseStateTests: XCTestCase {
    func testRunsOnlyWithoutReasons() {
        var state = PauseState()
        XCTAssertTrue(state.cameraShouldRun(calibrating: false))
        XCTAssertTrue(state.set(.onBattery, true))
        XCTAssertFalse(state.set(.onBattery, true))
        XCTAssertFalse(state.cameraShouldRun(calibrating: false))
        XCTAssertTrue(state.set(.onBattery, false))
        XCTAssertTrue(state.cameraShouldRun(calibrating: false))
    }

    func testPrimaryReasonFollowsPriority() {
        var state = PauseState()
        state.set(.notCalibrated, true)
        state.set(.onBattery, true)
        state.set(.screenLocked, true)
        XCTAssertEqual(state.primaryReason, .screenLocked)
    }

    func testCalibrationOverridesSoftReasonsOnly() {
        var state = PauseState()
        state.set(.user, true)
        state.set(.onBattery, true)
        state.set(.notCalibrated, true)
        XCTAssertTrue(state.cameraShouldRun(calibrating: true))
        state.set(.screenLocked, true)
        XCTAssertFalse(state.cameraShouldRun(calibrating: true))
    }
}

final class SampleStoreTests: XCTestCase {
    func testEvictsOldestClicksBeforeCalibration() {
        var store = SampleStore(maxPerScreen: 4)
        for i in 0..<2 {
            store.add(LabeledSample(screen: "a", sample: FaceSample(yaw: Double(i), pitch: 0), source: .calibration))
        }
        for i in 0..<4 {
            store.add(LabeledSample(screen: "a", sample: FaceSample(yaw: Double(10 + i), pitch: 0), source: .click))
        }
        XCTAssertEqual(store.count(for: "a"), 4)
        XCTAssertEqual(store.count(for: "a", source: .calibration), 2)
        XCTAssertEqual(store.samples(for: "a").filter { $0.source == .click }.map(\.sample.yaw), [12, 13])
    }

    func testResetScreenReplacesEverythingForThatScreen() {
        var store = SampleStore()
        store.add(LabeledSample(screen: "a", sample: FaceSample(yaw: 1, pitch: 0), source: .click))
        store.add(LabeledSample(screen: "b", sample: FaceSample(yaw: 2, pitch: 0), source: .click))
        store.resetScreen("a", with: [LabeledSample(screen: "a", sample: FaceSample(yaw: 3, pitch: 0), source: .calibration)])
        XCTAssertEqual(store.samples(for: "a").map(\.sample.yaw), [3])
        XCTAssertEqual(store.count(for: "b"), 1)
    }

    func testCodableRoundTrip() throws {
        var store = SampleStore()
        store.add(LabeledSample(
            screen: "builtin",
            sample: FaceSample(yaw: 1, pitch: 2, noseOffset: 0.1, eyeOffset: nil, timestamp: 5),
            source: .calibration
        ))
        let data = try JSONEncoder().encode(store)
        XCTAssertEqual(try JSONDecoder().decode(SampleStore.self, from: data), store)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"builtin\""))
    }
}

final class ActivityClockTests: XCTestCase {
    func testSlowsDownWhileUserIsBusy() {
        let clock = ActivityClock(mouseHold: 1.5, typingHold: 0.6)
        XCTAssertEqual(clock.frameInterval(at: 10, activeFPS: 12, heldFPS: 4), 1.0 / 12, accuracy: 1e-9)
        clock.noteMouse(at: 10)
        XCTAssertEqual(clock.frameInterval(at: 11, activeFPS: 12, heldFPS: 4), 0.25, accuracy: 1e-9)
        XCTAssertEqual(clock.frameInterval(at: 12, activeFPS: 12, heldFPS: 4), 1.0 / 12, accuracy: 1e-9)
        clock.noteKey(at: 20)
        XCTAssertEqual(clock.frameInterval(at: 20.3, activeFPS: 12, heldFPS: 4), 0.25, accuracy: 1e-9)
    }
}

import XCTest
@testable import PointrackerCore

final class FocusDeciderTests: XCTestCase {
    let a: ScreenID = "a"
    let b: ScreenID = "b"

    private func looking(at screen: ScreenID, score: Double = 0.95) -> Classification {
        let other: ScreenID = screen == a ? b : a
        return Classification(scores: [screen: score, other: 1 - score], nearestDistance: 0.3, isOutlier: false)
    }

    private func input(
        _ time: TimeInterval,
        _ classification: Classification?,
        current: ScreenID? = "a",
        mouse: TimeInterval? = nil,
        key: TimeInterval? = nil
    ) -> DeciderInput {
        DeciderInput(
            time: time,
            classification: classification,
            currentScreen: current,
            lastMouseActivity: mouse,
            lastKeyActivity: key
        )
    }

    func testSwitchesAfterDwell() {
        var decider = FocusDecider()
        XCTAssertEqual(decider.step(input(0.0, looking(at: b))), .tracking(b, progress: 0))
        XCTAssertNotEqual(decider.step(input(0.2, looking(at: b))), .switchTo(b))
        XCTAssertEqual(decider.step(input(0.31, looking(at: b))), .switchTo(b))
    }

    func testLookingAtCurrentScreenDoesNothing() {
        var decider = FocusDecider()
        XCTAssertEqual(decider.step(input(0.0, looking(at: a))), .idle)
        XCTAssertEqual(decider.step(input(1.0, looking(at: a))), .idle)
    }

    func testQuickGlanceIsIgnoredAndClockRestarts() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b)))
        _ = decider.step(input(0.2, looking(at: b)))
        XCTAssertEqual(decider.step(input(0.25, looking(at: a))), .idle)
        XCTAssertEqual(decider.step(input(0.3, looking(at: b))), .tracking(b, progress: 0))
        XCTAssertNotEqual(decider.step(input(0.5, looking(at: b))), .switchTo(b))
        XCTAssertEqual(decider.step(input(0.61, looking(at: b))), .switchTo(b))
    }

    func testHoldsWhileUsingMouseAndFor1500msAfter() {
        var decider = FocusDecider()
        XCTAssertEqual(decider.step(input(1.0, looking(at: b), mouse: 0)), .holding(.mouse))
        XCTAssertEqual(decider.step(input(1.4, looking(at: b), mouse: 0)), .holding(.mouse))
        XCTAssertEqual(decider.step(input(1.6, looking(at: b), mouse: 0)), .tracking(b, progress: 0))
        XCTAssertEqual(decider.step(input(1.91, looking(at: b), mouse: 0)), .switchTo(b))
    }

    func testHoldsWhileTyping() {
        var decider = FocusDecider()
        XCTAssertEqual(decider.step(input(0.5, looking(at: b), key: 0)), .holding(.typing))
        XCTAssertEqual(decider.step(input(0.7, looking(at: b), key: 0)), .tracking(b, progress: 0))
    }

    func testNeedsAClearLead() {
        var decider = FocusDecider()
        XCTAssertEqual(decider.step(input(0.0, looking(at: b, score: 0.55))), .idle)
        XCTAssertEqual(decider.step(input(1.0, looking(at: b, score: 0.55))), .idle)
    }

    func testOutlierResetsPendingSwitch() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b)))
        let away = Classification(scores: [b: 1], nearestDistance: 9, isOutlier: true)
        XCTAssertEqual(decider.step(input(0.2, away)), .idle)
        XCTAssertEqual(decider.step(input(0.3, looking(at: b))), .tracking(b, progress: 0))
    }

    func testTrustsOwnSwitchDuringCooldown() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b)))
        XCTAssertEqual(decider.step(input(0.31, looking(at: b))), .switchTo(b))
        // Caller still reports the old screen; must not start another switch.
        XCTAssertEqual(decider.step(input(0.35, looking(at: b), current: a)), .idle)
    }

    func testFaceLostWhileTurningFarStillCompletesSwitch() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b)))
        _ = decider.step(input(0.1, looking(at: b)))
        _ = decider.step(input(0.2, looking(at: b)))
        XCTAssertEqual(decider.step(input(0.31, nil)), .switchTo(b))
    }

    func testFaceLostAfterBriefGlanceDoesNotSwitch() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b)))
        XCTAssertEqual(decider.step(input(0.35, nil)), .tracking(b, progress: 1))
        XCTAssertEqual(decider.step(input(0.7, nil)), .idle)
        XCTAssertNil(decider.candidate)
    }

    func testUnknownCurrentScreenStillSwitches() {
        var decider = FocusDecider()
        _ = decider.step(input(0.0, looking(at: b), current: nil))
        XCTAssertEqual(decider.step(input(0.3, looking(at: b), current: nil)), .switchTo(b))
    }
}

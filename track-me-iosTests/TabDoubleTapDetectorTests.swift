import XCTest
@testable import track_me_ios

/// TASK-226. The objection to double-tap was that it taxes every single tap with a disambiguation
/// timeout. It does not here, and these are the cases that prove the rule stayed cheap and did not
/// start firing on taps a rider did not mean as a pair. Mirrors the Android suite.
final class TabDoubleTapDetectorTests: XCTestCase {

    func testFirstTapIsNeverADoubleTap() {
        var detector = TabDoubleTapDetector(window: 0.3)
        XCTAssertFalse(detector.tap(index: 1, now: 1.0))
    }

    func testTwoTapsOnTheSameTabInsideTheWindowAreADoubleTap() {
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 1, now: 1.0)
        XCTAssertTrue(detector.tap(index: 1, now: 1.2))
    }

    func testTwoTapsJustOutsideTheWindowAreTwoSingleTaps() {
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 1, now: 1.0)
        XCTAssertFalse(detector.tap(index: 1, now: 1.31))
    }

    /// Deliberately *not* asserted at the exact boundary. The window is a `TimeInterval`, so
    /// `1.3 - 1.0` is `0.30000000000000004` and an exact-boundary expectation tests floating-point
    /// representation rather than the rule. A tap a fraction inside is what a rider can actually
    /// produce, and that is what has to hold. (Android compares integer milliseconds, where the
    /// boundary is exact — the platforms agree on every timing a human can generate.)
    func testATapJustInsideTheWindowIsADoubleTap() {
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 1, now: 1.0)
        XCTAssertTrue(detector.tap(index: 1, now: 1.299))
    }

    func testAFastTapOnADifferentTabIsNotADoubleTap() {
        // Moving quickly between two tabs is ordinary use and must not pop either one.
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 1, now: 1.0)
        XCTAssertFalse(detector.tap(index: 2, now: 1.05))
    }

    func testThreeFastTapsAreOneDoubleTapAndOneSingle() {
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 0, now: 1.0)
        XCTAssertTrue(detector.tap(index: 0, now: 1.1))
        XCTAssertFalse(detector.tap(index: 0, now: 1.2), "the pair was consumed")
    }

    func testAFourthTapCanStartANewPair() {
        var detector = TabDoubleTapDetector(window: 0.3)
        _ = detector.tap(index: 0, now: 1.0)
        _ = detector.tap(index: 0, now: 1.1)
        _ = detector.tap(index: 0, now: 1.2)
        XCTAssertTrue(detector.tap(index: 0, now: 1.3))
    }
}

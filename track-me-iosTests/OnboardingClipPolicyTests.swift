import XCTest
@testable import track_me_ios

final class OnboardingClipPolicyTests: XCTestCase {
    func testReducedMotionAndDecodeFailureForceVectorFallback() {
        XCTAssertTrue(OnboardingClipPolicy.shouldRenderVideo(
            reduceMotion: false,
            assetAvailable: true,
            playerFailed: false
        ))
        XCTAssertFalse(OnboardingClipPolicy.shouldRenderVideo(
            reduceMotion: true,
            assetAvailable: true,
            playerFailed: false
        ))
        XCTAssertFalse(OnboardingClipPolicy.shouldRenderVideo(
            reduceMotion: false,
            assetAvailable: true,
            playerFailed: true
        ))
    }

    func testOffscreenOrInactiveSceneNeverPlays() {
        XCTAssertFalse(OnboardingClipPolicy.shouldPlay(
            isActive: false,
            sceneIsActive: true,
            canRender: true
        ))
        XCTAssertFalse(OnboardingClipPolicy.shouldPlay(
            isActive: true,
            sceneIsActive: false,
            canRender: true
        ))
        XCTAssertTrue(OnboardingClipPolicy.shouldPlay(
            isActive: true,
            sceneIsActive: true,
            canRender: true
        ))
    }
}

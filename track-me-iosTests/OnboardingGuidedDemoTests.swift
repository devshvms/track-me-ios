import Foundation
import XCTest
@testable import track_me_ios

final class OnboardingGuidedDemoTests: XCTestCase {
    func testFourStepProgressAdvancesAndCompletes() {
        XCTAssertEqual(OnboardingDemoProgress.nextStep(current: 0, count: 4), 1)
        XCTAssertEqual(OnboardingDemoProgress.nextStep(current: 1, count: 4), 2)
        XCTAssertEqual(OnboardingDemoProgress.nextStep(current: 2, count: 4), 3)
        XCTAssertNil(OnboardingDemoProgress.nextStep(current: 3, count: 4))
    }

    func testScrubRequiresMeaningfulTravel() {
        XCTAssertFalse(OnboardingDemoProgress.isMeaningfulScrub(startIndex: 0, currentIndex: 1, pointCount: 31))
        XCTAssertFalse(OnboardingDemoProgress.isMeaningfulScrub(startIndex: 0, currentIndex: 6, pointCount: 31))
        XCTAssertTrue(OnboardingDemoProgress.isMeaningfulScrub(startIndex: 0, currentIndex: 7, pointCount: 31))
    }

    func testGuidedDemosHaveNoServiceMapClipboardOrGalleryDependency() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("track-me-ios/Views/OnboardingGuidedDemos.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "TrackingManager.shared",
            "LiveSharingManager.shared",
            "UIPasteboard",
            "Map(",
            "MKMap",
            "ImageExporter",
            "Photos",
            "ModelContext"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Demo source must not contain \(forbidden)")
        }
        XCTAssertTrue(source.contains("RoutePreviewThumbnail("))
        XCTAssertTrue(source.contains("ExportPreviewView("))
    }

    func testEveryGuidedDemoStringHasAllSixTranslatedLocales() throws {
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("track-me-ios/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expectedLocales = Set(["de", "es", "fr", "hi", "ja", "zh-Hans"])
        let keys = [
            "Skip step",
            "Drag to choose how you're moving.",
            "Open live sharing and start a demo session.",
            "Open live sharing and try Copy link.",
            "Slide left to stop the demo ride.",
            "Open the sample ride.",
            "Scrub the route to inspect speed and elevation.",
            "Scroll down and tap Share.",
            "Customize the export, then save the demo.",
            "Sample ride",
            "In a real ride, Copy link would copy its private live-sharing URL.",
            "Demo only — nothing was shared or saved.",
            "Customize export"
        ]

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertTrue(expectedLocales.isSubset(of: Set(localizations.keys)), "Incomplete translations for \(key)")
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

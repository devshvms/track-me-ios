//
//  V192IntegrationTests.swift
//
//  End-to-end v1.9.2 integration tests covering:
//  - TASK-356: Orphaned ride recovery telemetry contracts + GPS pause/resume debounce
//  - TASK-358: Weekly recap open-source attribution ("notification" vs "in_app")
//  - TASK-359: Route card & weekly recap share channel resolution + deep link fallback
//

import XCTest
@testable import track_me_ios

final class V192IntegrationTests: XCTestCase {

    func testRecoveryToTelemetryEndToEndFlow() {
        // 1. Silent when no rides were recovered or discarded
        XCTAssertFalse(RecoveryTelemetry.shouldReport(recoveredCount: 0, discardedCount: 0))

        // 2. Emits coarse bucket only when rides are rescued
        XCTAssertTrue(RecoveryTelemetry.shouldReport(recoveredCount: 2, discardedCount: 1))
        let props = RecoveryTelemetry.properties(recoveredCount: 2, discardedCount: 1, totalMeters: 7_450)
        XCTAssertEqual(props["recovered_count"] as? Int, 2)
        XCTAssertEqual(props["discarded_count"] as? Int, 1)
        XCTAssertEqual(props["distance_bucket"] as? String, "5_20km")
        XCTAssertNil(props["distance_meters"])
        XCTAssertNil(props["ride_id"])
    }

    @MainActor
    func testWeeklyRecapOpenSourceStateMachine() {
        let coordinator = WeeklyRecapCoordinator.shared
        // Default open source is "in_app"
        XCTAssertEqual(coordinator.consumeOpenSource(), "in_app")

        // When notification tap marks open from notification, next consume returns "notification" once
        coordinator.markOpenedFromNotification()
        XCTAssertEqual(coordinator.consumeOpenSource(), "notification")
        // Subsequent organic opens revert to "in_app"
        XCTAssertEqual(coordinator.consumeOpenSource(), "in_app")
    }

    func testRouteCardAndRecapShareChannelResolution() {
        let channels: [(String?, String)] = [
            ("net.whatsapp.WhatsApp.ShareExtension", "whatsapp"),
            ("com.burbn.instagram.shareextension", "instagram"),
            ("ph.telegra.Telegraph.Share", "telegram"),
            ("com.atebits.Tweetie2.ShareExtension", "x"),
            ("com.strava.stravalink", "strava"),
            ("com.apple.UIKit.activity.Message", "sms"),
            ("com.apple.UIKit.activity.Mail", "email"),
            ("com.apple.UIKit.activity.AirDrop", "airdrop"),
            ("com.apple.UIKit.activity.CopyToPasteboard", "copy"),
            ("org. unknown.app", "other"),
            (nil, "unknown")
        ]
        for (input, expected) in channels {
            XCTAssertEqual(TelemetryManager.resolveShareChannel(input), expected)
        }
    }

    func testGpsTelemetryDebounceWindowIs60Seconds() {
        XCTAssertEqual(TrackingManager.gpsPauseTelemetryDebounce, 60.0)
    }
}

import Foundation
import XCTest
@testable import track_me_ios

final class VoiceCommandControllerTests: XCTestCase {
    func testAllStatusAgeBucketsMapToDefinedStructuredFreshness() {
        let members = [
            member("now", StatusAge.Anchor(ageAtReceiptMillis: 0, receivedAtElapsedMillis: 10_000, isKnown: true)),
            member("seconds", StatusAge.Anchor(ageAtReceiptMillis: 40_000, receivedAtElapsedMillis: 10_000, isKnown: true)),
            member("minutes", StatusAge.Anchor(ageAtReceiptMillis: 120_000, receivedAtElapsedMillis: 10_000, isKnown: true)),
            member("hours", StatusAge.Anchor(ageAtReceiptMillis: 3_600_000, receivedAtElapsedMillis: 10_000, isKnown: true)),
            member("unknown", .unknown(receivedAtElapsedMillis: 10_000))
        ]

        guard case let .available(_, facts) = VoiceCommandController.evaluateGroupCache(
            activeSnapshot(members: members),
            nowElapsedMillis: 10_000
        ) else {
            return XCTFail("expected available cache")
        }
        XCTAssertEqual(
            facts.map(\.freshness),
            [.now, .seconds(40), .minutes(2), .hours(1), .unknown]
        )
    }

    func testMissingAgeAnchorIsUnknownRatherThanGuessed() {
        guard case let .available(_, facts) = VoiceCommandController.evaluateGroupCache(
            activeSnapshot(members: [member("missing", nil)]),
            nowElapsedMillis: .max
        ) else {
            return XCTFail("expected available cache")
        }
        XCTAssertEqual(facts.first?.freshness, .unknown)
    }

    func testNoGroupEmptyCacheAndDegradedCacheStayDistinct() {
        XCTAssertEqual(
            VoiceCommandController.evaluateGroupCache(.noActiveGroup, nowElapsedMillis: 0),
            .noActiveGroup
        )
        XCTAssertEqual(
            VoiceCommandController.evaluateGroupCache(
                activeSnapshot(members: []),
                nowElapsedMillis: 0
            ),
            .empty(connection: .current)
        )
        XCTAssertEqual(
            VoiceCommandController.evaluateGroupCache(
                activeSnapshot(members: [], degraded: true),
                nowElapsedMillis: 0
            ),
            .empty(connection: .degraded)
        )
    }

    func testDegradedStateRemainsAttachedToUsableCachedMembers() {
        let result = VoiceCommandController.evaluateGroupCache(
            activeSnapshot(
                members: [
                    member(
                        "member-1",
                        StatusAge.Anchor(ageAtReceiptMillis: 0, receivedAtElapsedMillis: 0, isKnown: true)
                    )
                ],
                degraded: true
            ),
            nowElapsedMillis: 0
        )
        guard case let .available(connection, facts) = result else {
            return XCTFail("expected available cache")
        }
        XCTAssertEqual(connection, .degraded)
        XCTAssertEqual(facts.first?.cacheKey, "member-1")
    }

    func testEndIsTheOnlyActionRequiringConfirmation() {
        for action in VoiceAction.allCases {
            guard case let .actionReady(resultAction, requiresConfirmation) =
                VoiceCommandController.evaluate(.action(action)) else {
                return XCTFail("expected action result")
            }
            XCTAssertEqual(resultAction, action)
            XCTAssertEqual(requiresConfirmation, action == .end)
        }
    }

    func testCommandEvaluationReturnsTypedQueryResults() {
        XCTAssertEqual(
            VoiceCommandController.evaluate(.personalQuery(.distance)),
            .personalQueryReady(.distance)
        )
        XCTAssertEqual(
            VoiceCommandController.evaluate(.groupQuery(.roster)),
            .groupQueryReady(query: .roster, cache: .noActiveGroup)
        )
    }

    func testTelemetryNamesKeysAndValuesAreClosedAndCrossPlatformStable() {
        XCTAssertEqual(
            VoiceTelemetryContract.commandInvoked(intent: .start, surface: .assistant),
            VoiceTelemetryEvent(
                name: "voice_command_invoked",
                properties: ["intent": "start", "surface": "assistant"]
            )
        )
        XCTAssertEqual(
            VoiceTelemetryContract.commandFailed(intent: .groupMemberLocation, reason: .locked),
            VoiceTelemetryEvent(
                name: "voice_command_failed",
                properties: ["intent": "group_member_location", "reason": "locked"]
            )
        )
        XCTAssertEqual(
            VoiceTelemetryContract.queryAnswered(intent: .groupMemberLocation, freshness: .unknown),
            VoiceTelemetryEvent(
                name: "voice_query_answered",
                properties: ["intent": "group_member_location", "freshness_bucket": "unknown"]
            )
        )
        XCTAssertEqual(
            VoiceIntent.allCases.map(\.rawValue),
            [
                "start", "pause", "resume", "end", "personal_distance",
                "personal_pace_or_speed", "personal_duration", "group_member_location",
                "group_roster", "group_safety_status"
            ]
        )
        XCTAssertEqual(
            VoiceQueryIntent.allCases.map(\.rawValue),
            [
                "personal_distance", "personal_pace_or_speed", "personal_duration",
                "group_member_location", "group_roster", "group_safety_status"
            ]
        )
        XCTAssertEqual(
            VoiceFailureReason.allCases.map(\.rawValue),
            [
                "no_active_ride", "invalid_ride_state", "no_active_group", "empty_cache",
                "degraded", "locked", "member_not_found", "ambiguous_member", "unavailable"
            ]
        )
    }

    func testTelemetryPayloadCannotCarryPrivateVoiceOrGroupData() {
        let events = VoiceIntent.allCases.flatMap { intent in
            VoiceSurface.allCases.map {
                VoiceTelemetryContract.commandInvoked(intent: intent, surface: $0)
            } + VoiceFailureReason.allCases.map {
                VoiceTelemetryContract.commandFailed(intent: intent, reason: $0)
            }
        } + VoiceQueryIntent.allCases.flatMap { intent in
            VoiceFreshnessBucket.allCases.map {
                VoiceTelemetryContract.queryAnswered(intent: intent, freshness: $0)
            }
        }
        let allowedKeys = Set(["intent", "surface", "reason", "freshness_bucket"])
        let forbidden = [
            "utterance", "transcript", "name", "uid", "member", "group_id", "token",
            "lat", "lng", "coordinate", "distance"
        ]

        for event in events {
            XCTAssertTrue(Set(event.properties.keys).isSubset(of: allowedKeys))
            for key in event.properties.keys {
                XCTAssertFalse(forbidden.contains { key.localizedCaseInsensitiveContains($0) })
            }
        }
    }

    func testControllerSourceIsSynchronousMemoryOnlyAndHasNoRenderer() throws {
        let source = try productionSource()
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"//.*"#, with: "", options: .regularExpression)
        let forbidden = [
            "Date(", "ProcessInfo", "ContinuousClock", "SuspendingClock", "async ", "await ",
            "Task {", "URLSession", "URLRequest", "Network", "CoreData", "SwiftData", "UserDefaults",
            "FileManager", "JSONEncoder", "PostHog", "TelemetryManager", "AppIntent", "IntentDialog"
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "VoiceCommandController must not contain \(token)")
        }
        XCTAssertNil(
            source.range(
                of: #"func\s+\w+\([^)]*\)\s*->\s*String"#,
                options: .regularExpression
            ),
            "spoken formatting belongs to the voice catalogue, not the controller"
        )
    }

    private func member(_ key: String, _ anchor: StatusAge.Anchor?) -> VoiceGroupMemberCache {
        VoiceGroupMemberCache(cacheKey: key, displayName: "Rider", positionAgeAnchor: anchor)
    }

    private func activeSnapshot(
        members: [VoiceGroupMemberCache],
        degraded: Bool = false
    ) -> VoiceGroupCacheSnapshot {
        VoiceGroupCacheSnapshot(
            isActive: true,
            isDegraded: degraded,
            syncIntervalSec: 10,
            members: members
        )
    }

    private func productionSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repositoryRoot
            .appendingPathComponent("track-me-ios")
            .appendingPathComponent("Services")
            .appendingPathComponent("Voice")
            .appendingPathComponent("VoiceCommandController.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}

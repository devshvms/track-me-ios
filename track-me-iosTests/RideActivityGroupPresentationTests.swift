import Foundation
import XCTest
@testable import track_me_ios

@MainActor
final class RideActivityGroupPresentationTests: XCTestCase {
    private struct PreviousContentState: Codable {
        let startedAt: Date
        let distanceMeters: Double
        let speedMps: Double
        let isPaused: Bool
        let isGpsLost: Bool
        let pausedElapsed: TimeInterval
    }

    func testPreviousSchemaDecodesWithSafeGroupDefaults() throws {
        let previous = PreviousContentState(
            startedAt: Date(timeIntervalSinceReferenceDate: 12_345),
            distanceMeters: 4_321,
            speedMps: 7.5,
            isPaused: true,
            isGpsLost: false,
            pausedElapsed: 98
        )

        let payload = try JSONEncoder().encode(previous)
        let decoded = try JSONDecoder().decode(
            RideActivityAttributes.ContentState.self,
            from: payload
        )

        XCTAssertEqual(decoded.startedAt, previous.startedAt)
        XCTAssertEqual(decoded.distanceMeters, previous.distanceMeters)
        XCTAssertEqual(decoded.speedMps, previous.speedMps)
        XCTAssertEqual(decoded.isPaused, previous.isPaused)
        XCTAssertEqual(decoded.isGpsLost, previous.isGpsLost)
        XCTAssertEqual(decoded.pausedElapsed, previous.pausedElapsed)
        XCTAssertEqual(decoded.groupMemberCount, 0)
        XCTAssertEqual(decoded.alertSignal, .none)
        XCTAssertEqual(decoded.alertMemberName, "")
        XCTAssertEqual(decoded.alertStatusCode, "")
    }

    func testContentStatePayloadContainsOnlyApprovedAggregateFields() throws {
        let payload = try JSONEncoder().encode(
            state(
                memberCount: 4,
                signal: .raised,
                memberName: "Asha",
                statusCode: "1GNH"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "startedAt", "distanceMeters", "speedMps", "isPaused",
                "isGpsLost", "pausedElapsed", "groupMemberCount",
                "alertSignal", "alertMemberName", "alertStatusCode"
            ])
        )
        XCTAssertFalse(object.keys.contains { key in
            let normalized = key.lowercased()
            return normalized.contains("latitude") || normalized.contains("longitude") ||
                normalized == "lat" || normalized == "lng" ||
                normalized.contains("coordinate") || normalized.contains("direction")
        })
    }

    func testBottomContentUsesAlertGpsPausedRecordingPrecedence() {
        XCTAssertEqual(
            RideActivityFormat.bottomContent(
                state(paused: true, gpsLost: true, signal: .raised, memberName: "李雷", statusCode: "1GNH")
            ),
            .alert(RideActivityFormat.alertLine(
                state(paused: true, gpsLost: true, signal: .raised, memberName: "李雷", statusCode: "1GNH")
            )!)
        )
        XCTAssertEqual(
            RideActivityFormat.bottomContent(state(paused: true, gpsLost: true)),
            .gpsLost
        )
        XCTAssertEqual(RideActivityFormat.bottomContent(state(paused: true)), .paused)
        XCTAssertEqual(RideActivityFormat.bottomContent(state()), .recording)
    }

    func testMemberCountAppearsOnlyForAQuietGroup() {
        XCTAssertNil(RideActivityFormat.memberCountLine(state(memberCount: 0)))
        XCTAssertNotNil(RideActivityFormat.memberCountLine(state(memberCount: 4)))
        XCTAssertNil(
            RideActivityFormat.memberCountLine(
                state(memberCount: 4, signal: .raised, memberName: "Asha", statusCode: "1GNH")
            )
        )
    }

    func testNonLatinMemberNameIsPreservedAsCompleteGraphemes() throws {
        let name = "अनुष्का 👩🏽‍🚴🏾 李雷"
        let alert = try XCTUnwrap(
            RideActivityFormat.alertLine(
                state(signal: .raised, memberName: name, statusCode: "1GCR")
            )
        )

        XCTAssertTrue(alert.contains(name))

        let widgetSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("TrackMeWidgets/RideLiveActivity.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(widgetSource.contains(".prefix("))
        XCTAssertFalse(widgetSource.contains("utf8"))
        XCTAssertFalse(widgetSource.contains("utf16"))
    }

    func testRepeatedSyncsEmitOnlyForRenderedBucketOrAlertSignalChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var gate = RideActivityUpdateGate(minimumMetricInterval: 15)
        var emitted = 0

        func count(
            _ snapshot: RideActivityDisplaySnapshot,
            seconds: TimeInterval,
            gate: inout RideActivityUpdateGate,
            emitted: inout Int
        ) {
            if gate.shouldEmit(snapshot, at: start.addingTimeInterval(seconds)) {
                emitted += 1
            }
        }

        let quiet = RideActivityDisplaySnapshot(state: state(memberCount: 3))
        count(quiet, seconds: 0, gate: &gate, emitted: &emitted)
        count(quiet, seconds: 10, gate: &gate, emitted: &emitted)
        count(quiet, seconds: 20, gate: &gate, emitted: &emitted)

        let memberJoined = RideActivityDisplaySnapshot(state: state(memberCount: 4))
        count(memberJoined, seconds: 21, gate: &gate, emitted: &emitted)
        count(memberJoined, seconds: 31, gate: &gate, emitted: &emitted)

        let distanceCrossed = RideActivityDisplaySnapshot(
            state: state(distanceMeters: 30, memberCount: 4)
        )
        count(distanceCrossed, seconds: 32, gate: &gate, emitted: &emitted)
        count(distanceCrossed, seconds: 37, gate: &gate, emitted: &emitted)

        let raised = RideActivityDisplaySnapshot(
            state: state(
                distanceMeters: 30,
                memberCount: 4,
                signal: .raised,
                memberName: "Asha",
                statusCode: "1GNH"
            )
        )
        count(raised, seconds: 38, gate: &gate, emitted: &emitted)
        count(raised, seconds: 48, gate: &gate, emitted: &emitted)

        let resolved = RideActivityDisplaySnapshot(
            state: state(distanceMeters: 30, memberCount: 4, signal: .resolved)
        )
        count(resolved, seconds: 49, gate: &gate, emitted: &emitted)

        XCTAssertEqual(
            emitted,
            5,
            "initial, member-count, distance bucket, alert-raised, and alert-resolved only"
        )
    }

    func testMetricBucketsMatchTheRenderedPrecision() {
        let base = state(distanceMeters: 0, speedMps: 0)
        let belowDistanceBoundary = state(distanceMeters: 4, speedMps: 0)
        let crossedDistanceBoundary = state(distanceMeters: 6, speedMps: 0)
        let belowSpeedBoundary = state(distanceMeters: 0, speedMps: 0.01)
        let crossedSpeedBoundary = state(distanceMeters: 0, speedMps: 0.02)

        XCTAssertEqual(
            RideActivityDisplaySnapshot(state: base).distanceBucket,
            RideActivityDisplaySnapshot(state: belowDistanceBoundary).distanceBucket
        )
        XCTAssertNotEqual(
            RideActivityDisplaySnapshot(state: base).distanceBucket,
            RideActivityDisplaySnapshot(state: crossedDistanceBoundary).distanceBucket
        )
        XCTAssertEqual(
            RideActivityDisplaySnapshot(state: base).speedBucket,
            RideActivityDisplaySnapshot(state: belowSpeedBoundary).speedBucket
        )
        XCTAssertNotEqual(
            RideActivityDisplaySnapshot(state: base).speedBucket,
            RideActivityDisplaySnapshot(state: crossedSpeedBoundary).speedBucket
        )
    }

    func testWidgetCatalogueCoversEveryVisualStringInAllSevenLocales() throws {
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("TrackMeWidgets/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expectedLocales = Set(["en", "es", "fr", "de", "hi", "ja", "zh-Hans"])
        let requiredKeys = [
            "%@ — %@", "%d riding", "Crashed", "Distance", "Need help",
            "Paused", "Recording ride", "Searching for GPS…", "Speed",
            "Status needs attention"
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), expectedLocales, key)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func state(
        distanceMeters: Double = 0,
        speedMps: Double = 0,
        paused: Bool = false,
        gpsLost: Bool = false,
        memberCount: Int = 0,
        signal: RideActivityAlertSignal = .none,
        memberName: String = "",
        statusCode: String = ""
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            distanceMeters: distanceMeters,
            speedMps: speedMps,
            isPaused: paused,
            isGpsLost: gpsLost,
            pausedElapsed: 0,
            groupMemberCount: memberCount,
            alertSignal: signal,
            alertMemberName: memberName,
            alertStatusCode: statusCode
        )
    }
}

import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.3 scenario 12a and §6.1.2 scenario 10b, proved against the frozen vectors.
///
/// `ride-history-profile-v1.json` is canonical in `track-me-web/tests/fixtures` and copied verbatim
/// to both clients. Most of these cases assert a *refusal*, which is the half that matters: the
/// distinction between the shipped 12a and the cut 12 is entirely about when the app declines to
/// guess, and a platform that guesses where the other stays quiet is the app appearing to watch
/// more closely on one phone than on the other.
///
/// Read from the repository rather than a test bundle so the file asserted against is the same file
/// a reviewer diffs — a copy bundled at build time can go stale without failing.
final class RideHistoryProfileVectorsTests: XCTestCase {

    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/ride-history-profile-v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
            let alternative = directory
                .appendingPathComponent("track-me-iosTests/Resources/ride-history-profile-v1.json")
            if FileManager.default.fileExists(atPath: alternative.path) { found = alternative; break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "ride-history-profile-v1.json not found")
        vectors = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(vectors[key] as? [[String: Any]], "missing vector group: \(key)")
    }

    private func samples(_ raw: Any?) throws -> [RideHistoryProfile.Sample] {
        let array = try XCTUnwrap(raw as? [[String: Any]])
        return try array.map { entry in
            RideHistoryProfile.Sample(
                dayOfWeek: try XCTUnwrap(entry["day_of_week"] as? Int),
                hour: try XCTUnwrap(entry["hour"] as? Int),
                activeMinutes: Int64(try XCTUnwrap(entry["active_minutes"] as? Int)),
                persona: try XCTUnwrap(entry["persona"] as? String)
            )
        }
    }

    func testTheConstantsInTheVectorFileAreTheConstantsInTheCode() throws {
        let constants = try XCTUnwrap(vectors["constants"] as? [String: Any])
        XCTAssertEqual(constants["min_rides_for_suggestion"] as? Int, RideHistoryProfile.minRidesForSuggestion)
        XCTAssertEqual(constants["min_rides_on_dominant_day"] as? Int, RideHistoryProfile.minRidesOnDominantDay)
        XCTAssertEqual(
            try XCTUnwrap(constants["min_dominant_day_share"] as? Double),
            RideHistoryProfile.minDominantDayShare,
            accuracy: 0.0001
        )
    }

    func testEverySuggestedSlotVectorAgrees() throws {
        let group = try cases("suggest_slot")
        XCTAssertGreaterThanOrEqual(group.count, 8, "vectors went missing")
        for testCase in group {
            let description = try XCTUnwrap(testCase["description"] as? String)
            let actual = RideHistoryProfile.suggestSlot(try samples(testCase["samples"]))

            guard let expected = testCase["expected"] as? [String: Any] else {
                XCTAssertNil(actual, "\(description): expected no suggestion")
                continue
            }
            let slot = try XCTUnwrap(actual, "\(description): expected a suggestion, got none")
            XCTAssertEqual(slot.dayOfWeek, expected["day_of_week"] as? Int, "\(description): day")
            XCTAssertEqual(slot.hour, expected["hour"] as? Int, "\(description): hour")
            XCTAssertEqual(slot.persona, expected["persona"] as? String, "\(description): persona")
            XCTAssertEqual(slot.rideCount, expected["ride_count"] as? Int, "\(description): ride count")
        }
    }

    func testEveryTypicalActiveMinutesVectorAgrees() throws {
        let group = try cases("typical_active_minutes")
        XCTAssertGreaterThanOrEqual(group.count, 6, "vectors went missing")
        for testCase in group {
            let description = try XCTUnwrap(testCase["description"] as? String)
            let actual = RideHistoryProfile.typicalActiveMinutes(
                try samples(testCase["samples"]),
                persona: testCase["persona"] as? String
            )
            if let expected = testCase["expected"] as? Int {
                XCTAssertEqual(actual, Int64(expected), description)
            } else {
                XCTAssertNil(actual, "\(description): expected nil")
            }
        }
    }

    func testEveryStartButtonProximityVectorAgrees() throws {
        let group = try cases("start_button_proximity")
        XCTAssertGreaterThanOrEqual(group.count, 9, "vectors went missing")
        for testCase in group {
            let description = try XCTUnwrap(testCase["description"] as? String)
            let actual = StartButtonProximity.line(
                minutesToNextLevel: (testCase["minutes_to_next_level"] as? Int).map(Int64.init),
                nextLevelName: testCase["next_level_name"] as? String,
                typicalActiveMinutes: (testCase["typical_active_minutes"] as? Int).map(Int64.init)
            )
            guard let expected = testCase["expected"] as? [String: Any] else {
                XCTAssertNil(actual, "\(description): expected no line")
                continue
            }
            let line = try XCTUnwrap(actual, "\(description): expected a line, got none")
            XCTAssertEqual(line.minutes, Int64(try XCTUnwrap(expected["minutes"] as? Int)), "\(description): minutes")
            XCTAssertEqual(line.levelName, expected["level_name"] as? String, "\(description): level")
        }
    }

    /// The vectors number weekdays the ISO way. `Foundation`'s own weekday makes Sunday 1, so the
    /// conversion has to happen at the platform boundary. This asserts the policy itself never sees
    /// a 0 or an 8, which is what a missed conversion looks like.
    func testThePolicyRejectsWeekdayNumbersOutsideTheISORange() {
        for bad in [0, 8, -1] {
            XCTAssertFalse(
                ActivityReminder.Settings(enabled: true, dayOfWeek: bad).isValid,
                "\(bad) should not be a valid reminder weekday"
            )
        }
        for good in 1...7 {
            XCTAssertTrue(
                ActivityReminder.Settings(enabled: true, dayOfWeek: good).isValid,
                "\(good) should be a valid reminder weekday"
            )
        }
    }
}

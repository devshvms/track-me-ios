import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.1.7 — the bulletin, case for case with Android's three test files.
///
/// The bulletin is what makes §6.0's one-per-week notification cap a trade rather than a loss. If
/// the feed loses rows, duplicates them, or lies about what is unread, the cap stops being a trade.
@MainActor
final class BulletinTests: XCTestCase {

    private func isolated() -> BulletinStore {
        BulletinStore(defaults: UserDefaults(suiteName: "BulletinTests.\(UUID().uuidString)")!)
    }

    private func entry(_ id: String, _ at: Int64, kind: BulletinKind = .weeklyRecap) -> BulletinEntry {
        BulletinEntry(id: id, kind: kind, createdAtMillis: at,
                      facts: [BulletinEntry.factRideCount: "3"])
    }

    // MARK: - Store

    func testEntriesSurviveARestartWithTheirFacts() {
        let defaults = UserDefaults(suiteName: "BulletinTests.\(UUID().uuidString)")!
        BulletinStore(defaults: defaults).add(entry("a", 100))
        let reopened = BulletinStore(defaults: defaults)
        XCTAssertEqual(reopened.entries.map(\.id), ["a"])
        XCTAssertEqual(reopened.entries.first?.fact(BulletinEntry.factRideCount), "3")
    }

    func testTheSameFactArrivingTwiceAppearsOnce() {
        // A broadcast arrives by push AND by the foreground reconcile; a recap is notified AND read
        // in-app. A duplicated row would make the unread badge lie.
        let store = isolated()
        XCTAssertTrue(store.add(entry("a", 100)))
        XCTAssertFalse(store.add(entry("a", 100)))
        XCTAssertFalse(store.add(entry("a", 999)))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testTheFeedIsNewestFirstAndCapped() {
        let store = isolated()
        for index in 0..<(BulletinEntry.maxRetained + 10) {
            store.add(entry("e\(index)", Int64(index)))
        }
        XCTAssertEqual(store.entries.count, BulletinEntry.maxRetained)
        XCTAssertEqual(store.entries.first?.id, "e59", "the newest must survive, not the oldest")
    }

    func testEverythingIsUnreadUntilTheBulletinIsOpened() {
        let store = isolated()
        store.add(entry("a", 100))
        store.add(entry("b", 200))
        XCTAssertEqual(store.unread().count, 2)
        store.markAllSeen()
        XCTAssertEqual(store.unread().count, 0)
        store.add(entry("c", 300))
        XCTAssertEqual(store.unread().map(\.id), ["c"])
    }

    func testMarkAllSeenNeverMovesBackwards() {
        // A reconcile that back-fills history must not reopen the badge.
        let store = isolated()
        store.add(entry("new", 500))
        store.markAllSeen()
        store.add(entry("backdated", 100))
        XCTAssertEqual(store.unread().count, 0)
    }

    func testARowWithAnUnknownKindIsDroppedOnRead() {
        // A downgrade after a future release added a kind. Rendering it would be a blank line.
        let defaults = UserDefaults(suiteName: "BulletinTests.\(UUID().uuidString)")!
        defaults.set(
            #"[{"id":"x","kind":"FROM_THE_FUTURE","created_at_millis":1,"facts":{}}]"#,
            forKey: "trackme_bulletin_entries"
        )
        XCTAssertTrue(BulletinStore(defaults: defaults).entries.isEmpty)
    }

    func testACorruptedFeedYieldsNothingRatherThanCrashing() {
        let defaults = UserDefaults(suiteName: "BulletinTests.\(UUID().uuidString)")!
        defaults.set("{not json", forKey: "trackme_bulletin_entries")
        XCTAssertTrue(BulletinStore(defaults: defaults).entries.isEmpty)
    }

    // MARK: - Adapters

    func testABroadcastIsKeyedByItsOwnIdSoTwoArrivalsAreOneRow() {
        let broadcast = OperatorBroadcast(
            id: "b1", tag: .maintenance, title: "Cloud sync is paused",
            body: "Back in two hours.", createdAtMillis: 1_757_000_000_000,
            learnMoreUrl: "https://trackme.shvms.in/blogs"
        )
        XCTAssertEqual(BulletinAdapters.from(broadcast).id, BulletinAdapters.from(broadcast).id)
        XCTAssertEqual(BulletinAdapters.from(broadcast).fact(BulletinEntry.factTitle), "Cloud sync is paused")
    }

    func testARecapSortsByTheWeekItDescribesNotWhenItWasNoticed() {
        // Otherwise a recap read late sorts above facts that actually happened after it, and the
        // feed stops being a timeline of what happened.
        let older = BulletinAdapters.from(WeeklyRecap(weekKey: "W29", weekStartEpochDay: 20_000, rideCount: 2, distanceMeters: 1, streakWeeks: 1))
        let newer = BulletinAdapters.from(WeeklyRecap(weekKey: "W30", weekStartEpochDay: 20_007, rideCount: 2, distanceMeters: 1, streakWeeks: 2))
        XCTAssertGreaterThan(newer.createdAtMillis, older.createdAtMillis)
    }

    func testRecoveryProducesOneRowPerRideAndNoneForDiscards() {
        // The notification says "3 rides were saved" because it has one line. The feed has room to
        // say which three. A discarded empty ride produces nothing, matching the notification — a
        // row saying an empty ride was removed reads as "we deleted something of yours".
        var summary = RecoverySummary(recoveredCount: 2, discardedCount: 4)
        summary.recovered = [
            RecoveredRide(endTime: Date(timeIntervalSince1970: 1), distanceMeters: 12_345),
            RecoveredRide(endTime: Date(timeIntervalSince1970: 2), distanceMeters: 500),
        ]
        let entries = BulletinAdapters.from(summary)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .rideSaved })

        let discardsOnly = RecoverySummary(recoveredCount: 0, discardedCount: 4)
        XCTAssertTrue(BulletinAdapters.from(discardsOnly).isEmpty)
    }

    func testNoAdapterEverStoresACoordinateATitleOrSomethingNotOurs() {
        // The bulletin renders on a screen someone may hand to a friend, and a ride title can be
        // anything a user typed. Facts are counts, distances, timestamps and ids.
        var summary = RecoverySummary(recoveredCount: 1, discardedCount: 0)
        summary.recovered = [RecoveredRide(endTime: Date(timeIntervalSince1970: 1), distanceMeters: 10)]
        let entries = BulletinAdapters.from(summary)
            + [BulletinAdapters.from(WeeklyRecap(weekKey: "W30", weekStartEpochDay: 20_000, rideCount: 3, distanceMeters: 41_200, streakWeeks: 6))]

        let allowed: Set<String> = [
            BulletinEntry.factRideCount,
            BulletinEntry.factDistanceMeters,
            BulletinEntry.factStreakWeeks,
            BulletinEntry.factEndedAtMillis,
        ]
        for entry in entries {
            for key in entry.facts.keys {
                XCTAssertTrue(allowed.contains(key), "unexpected fact key '\(key)' — is it PII?")
            }
        }
    }

    // MARK: - Copy

    private struct FakeStrings: BulletinCopy.Strings {
        var rideSavedTitle = "Your ride was saved"
        var rideSavedBodyPlain = "The app closed while you were recording."
        func rideSavedBody(endedAt: String, distance: String) -> String {
            "Recording stopped at \(endedAt). \(distance) was kept."
        }
        var weeklyRecapTitle = "Last week"
        func weeklyRecapBody(rides: Int, distance: String) -> String { "\(rides) activities, \(distance)." }
        func levelReachedTitle(level: String) -> String { "You reached \(level)" }
        var levelReachedBody = "Keep going."
        func milestoneTitle(count: Int) -> String { "\(count) rides" }
        var milestoneBody = "A milestone."
        var syncProblemTitle = "Backup is not working"
        func syncProblemBody(unsynced: Int, since: String) -> String { "\(unsynced) since \(since)." }
        func versionNoteTitle(version: String) -> String { "TrackMe \(version)" }
        var versionNoteBody = "See what changed."
    }

    func testAZeroRideWeekNeverReachesTheFeedEither() {
        // §4.2 N2 is written about notifications, but a row reading "0 activities" is the same
        // sentence with a quieter delivery.
        XCTAssertNil(BulletinCopy.render(
            BulletinEntry(id: "e", kind: .weeklyRecap, createdAtMillis: 1, facts: [
                BulletinEntry.factRideCount: "0",
                BulletinCopy.formattedDistance: "0 km",
            ]),
            strings: FakeStrings()
        ))
    }

    func testAnEntryWithMissingFactsIsDroppedNotPaddedWithAPlaceholder() {
        // A row reading "—" is worse than a row that is not there: it looks like the app knows
        // something and will not say it.
        for kind in [BulletinKind.levelReached, .milestone, .syncProblem, .versionNote, .weeklyRecap, .broadcast] {
            XCTAssertNil(
                BulletinCopy.render(
                    BulletinEntry(id: "e", kind: kind, createdAtMillis: 1),
                    strings: FakeStrings()
                ),
                kind.rawValue
            )
        }
    }

    func testASavedRideFallsBackToThePlainSentenceRatherThanHalfOfOne() {
        XCTAssertEqual(
            BulletinCopy.render(
                BulletinEntry(id: "e", kind: .rideSaved, createdAtMillis: 1,
                              facts: [BulletinCopy.formattedEndedAt: "14:32"]),
                strings: FakeStrings()
            ),
            BulletinCopy.Row(title: "Your ride was saved", body: "The app closed while you were recording.")
        )
    }

    func testTheKindVocabularyMatchesAndroidExactly() {
        // The raw values are the persisted format. A rename on one platform would silently drop
        // every stored row of that kind on the other after a restore.
        XCTAssertEqual(
            BulletinKind.allCases.map(\.rawValue),
            ["BROADCAST", "RIDE_SAVED", "SYNC_PROBLEM", "WEEKLY_RECAP", "LEVEL_REACHED", "MILESTONE", "VERSION_NOTE"]
        )
    }
}

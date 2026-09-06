import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.0 — the interruption budget, proved against the frozen cross-platform vectors.
///
/// The vectors are the contract, not this file. `notification-budget-v1.json` is canonical in
/// `track-me-web/tests/fixtures` and copied verbatim to both clients, because a divergence here is
/// invisible until it is a review: one platform notifying weekly where the other notifies daily is
/// the difference between a differentiator and an uninstall, and neither platform's own suite would
/// notice on its own.
///
/// Read from the repository rather than from a test bundle so the file that is asserted against is
/// the same file a reviewer diffs — a copy bundled at build time can go stale without failing.
final class NotificationBudgetVectorsTests: XCTestCase {

    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/notification-budget-v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
            let alternative = directory
                .appendingPathComponent("track-me-iosTests/Resources/notification-budget-v1.json")
            if FileManager.default.fileExists(atPath: alternative.path) { found = alternative; break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "notification-budget-v1.json not found")
        vectors = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    // MARK: - Helpers

    private func cases(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(vectors[key] as? [[String: Any]], "missing vector group: \(key)")
    }

    private func klass(_ id: String) throws -> NotificationBudget.Klass {
        try XCTUnwrap(NotificationBudget.Klass(rawValue: id), "unknown class \(id)")
    }

    private func kind(_ id: String) throws -> NotificationBudget.ProactiveKind {
        try XCTUnwrap(NotificationBudget.ProactiveKind(rawValue: id), "unknown kind \(id)")
    }

    /// `NSNull` and "absent" both mean nil here; a vector saying `null` must not read as 0, which
    /// is a real timestamp meaning 1 January 1970 and would open the budget rather than close it.
    private func millis(_ vector: [String: Any], _ key: String) -> Int64? {
        guard let raw = vector[key], !(raw is NSNull) else { return nil }
        return (raw as? NSNumber)?.int64Value
    }

    private func note(_ vector: [String: Any], _ fallback: String) -> String {
        (vector["note"] as? String) ?? (vector["description"] as? String) ?? fallback
    }

    // MARK: - Vectors

    func testTheConstantsInTheVectorFileAreTheConstantsInTheCode() throws {
        // The vectors carry the intervals so neither platform can quietly pick its own. Without
        // this, every timing case below still passes on each platform separately.
        let constants = try XCTUnwrap(vectors["constants"] as? [String: Any])
        XCTAssertEqual(
            (constants["proactive_interval_millis"] as? NSNumber)?.int64Value,
            NotificationBudget.proactiveIntervalMillis
        )
        XCTAssertEqual(
            (constants["return_notice_interval_millis"] as? NSNumber)?.int64Value,
            NotificationBudget.returnNoticeIntervalMillis
        )
    }

    func testEveryClassDeclaresTheSameBudgetParticipationOnBothPlatforms() throws {
        let declared = try cases("classes")
        XCTAssertEqual(declared.count, NotificationBudget.Klass.allCases.count)
        for vector in declared {
            let k = try klass(XCTUnwrap(vector["id"] as? String))
            XCTAssertEqual(
                k.spendsProactiveBudget,
                vector["spends_proactive_budget"] as? Bool,
                "\(k.rawValue) spends_proactive_budget"
            )
        }
    }

    func testAllowsMatchesEveryVector() throws {
        let all = try cases("allows")
        XCTAssertGreaterThanOrEqual(all.count, 9, "the vector file lost its allows cases")
        for vector in all {
            let actual = NotificationBudget.allows(
                try klass(XCTUnwrap(vector["class"] as? String)),
                nowMillis: try XCTUnwrap(millis(vector, "now")),
                lastProactiveSentAtMillis: millis(vector, "last_proactive_at")
            )
            XCTAssertEqual(actual, vector["expected"] as? Bool, note(vector, "allows"))
        }
    }

    func testTheLedgerMovesOnlyForProactiveSendsAndNeverBackwards() throws {
        let all = try cases("ledger")
        XCTAssertGreaterThanOrEqual(all.count, 6)
        for vector in all {
            let actual = NotificationBudget.recordSent(
                try klass(XCTUnwrap(vector["class"] as? String)),
                sentAtMillis: try XCTUnwrap(millis(vector, "sent_at")),
                lastProactiveSentAtMillis: millis(vector, "last_proactive_at_before")
            )
            XCTAssertEqual(
                actual,
                millis(vector, "expected_last_proactive_at_after"),
                note(vector, "ledger")
            )
        }
    }

    func testTheDeclaredPriorityOrderMatchesTheVectorRanks() throws {
        let ranks = try cases("proactive_priority")
        XCTAssertEqual(ranks.count, NotificationBudget.ProactiveKind.allCases.count)
        for vector in ranks {
            let id = try XCTUnwrap(vector["id"] as? String)
            let index = NotificationBudget.ProactiveKind.allCases
                .firstIndex(of: try kind(id))
            XCTAssertEqual(index, vector["rank"] as? Int, "rank of \(id)")
        }
    }

    func testChooseMatchesEveryVectorWhateverOrderTheEligibleSetArrivesIn() throws {
        for vector in try cases("choose") {
            let eligible = Set(try (vector["eligible"] as? [String] ?? []).map(kind))
            let actual = NotificationBudget.choose(eligible)
            if let expected = vector["expected"] as? String {
                XCTAssertEqual(actual, try kind(expected), note(vector, "choose"))
            } else {
                XCTAssertNil(actual, note(vector, "choose"))
            }
        }
    }

    func testTheReturnNoticeMatchesEveryVector() throws {
        let all = try cases("return_notice")
        XCTAssertGreaterThanOrEqual(all.count, 6)
        for vector in all {
            let actual = NotificationBudget.allowsReturnNotice(
                nowMillis: try XCTUnwrap(millis(vector, "now")),
                lastReturnNoticeAtMillis: millis(vector, "last_return_notice_at"),
                daysSinceLastActivity: try XCTUnwrap(vector["days_since_activity"] as? Int)
            )
            XCTAssertEqual(actual, vector["expected"] as? Bool, note(vector, "return_notice"))
        }
    }

    // MARK: - Properties no single vector states

    func testARefusedProactiveNotificationIsNotConsumed() {
        // The property the whole cap rests on: querying the budget must never change it. A cap that
        // lost notifications instead of deferring them would make one-per-week a real restriction
        // rather than an honest one.
        let ledger: Int64 = 1_000
        for _ in 0..<5 {
            _ = NotificationBudget.allows(.proactive, nowMillis: 1_500, lastProactiveSentAtMillis: ledger)
        }
        XCTAssertEqual(
            NotificationBudget.recordSent(.operatorBroadcast, sentAtMillis: 9_999, lastProactiveSentAtMillis: ledger),
            ledger
        )
        XCTAssertTrue(
            NotificationBudget.allows(
                .proactive,
                nowMillis: ledger + NotificationBudget.proactiveIntervalMillis,
                lastProactiveSentAtMillis: ledger
            ),
            "the week must still open on schedule after any number of refusals"
        )
    }

    func testAnOperatorBroadcastCanNeverMuteTheProductsOwnVoice() {
        // §6.3: Class D sits outside the C budget in both directions. If a broadcast advanced the
        // ledger, "send a broadcast" would become a lever on engagement — which is exactly what the
        // promotional ban exists to prevent, expressed as arithmetic rather than as a rule.
        var ledger: Int64?
        for _ in 0..<10 {
            ledger = NotificationBudget.recordSent(.operatorBroadcast, sentAtMillis: 5_000, lastProactiveSentAtMillis: ledger)
        }
        XCTAssertNil(ledger)
        XCTAssertTrue(NotificationBudget.allows(.proactive, nowMillis: 5_000, lastProactiveSentAtMillis: ledger))
    }
}

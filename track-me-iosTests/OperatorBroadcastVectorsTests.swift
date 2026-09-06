import XCTest
@testable import track_me_ios

/// SCOPE_1.8.7 §6.3 — the Class D wire contract, proved against the frozen vectors.
///
/// Three implementations have to agree on this shape: the admin endpoint that writes it, and two
/// clients that read it. The asymmetry of the failures is why the rejection cases outnumber the
/// acceptances almost four to one — a client that drops a good broadcast costs a delay, while a
/// client that renders a bad one has taken an unvalidated network string to the user's lock screen.
@MainActor
final class OperatorBroadcastVectorsTests: XCTestCase {

    private var vectors: [String: Any]!

    override func setUpWithError() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            for candidate in [
                directory.appendingPathComponent("Resources/operator-broadcast-v1.json"),
                directory.appendingPathComponent("track-me-iosTests/Resources/operator-broadcast-v1.json"),
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
            }
            if found != nil { break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "operator-broadcast-v1.json not found")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func group(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(vectors[key] as? [[String: Any]], "missing vector group: \(key)")
    }

    func testTheTagVocabularyIsExactlyWhatTheContractDeclares() throws {
        let declared = try group("tags").compactMap { $0["id"] as? String }
        XCTAssertEqual(
            declared, BroadcastTag.allCases.map(\.rawValue),
            "adding a tag must be a three-codebase change, not a one-line one"
        )
    }

    func testEveryValidVectorParsesAndAppliesWhereTheContractSaysItApplies() throws {
        let cases = try group("valid")
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for vector in cases {
            let description = (vector["description"] as? String) ?? "valid"
            let record = try XCTUnwrap(vector["record"] as? [String: Any], description)
            let parsed = try XCTUnwrap(OperatorBroadcast.parse(record), description)
            XCTAssertEqual(
                parsed.applies(toVersionCode: try XCTUnwrap(vector["applies_to_version_code"] as? Int)),
                vector["expected_applies"] as? Bool,
                description
            )
        }
    }

    func testEveryInvalidVectorIsRefused() throws {
        let cases = try group("invalid")
        XCTAssertGreaterThanOrEqual(cases.count, 14, "the vector file lost its rejection cases")
        for vector in cases {
            let description = (vector["description"] as? String) ?? "invalid"
            let record = try XCTUnwrap(vector["record"] as? [String: Any], description)
            XCTAssertNil(OperatorBroadcast.parse(record), description)
        }
    }

    func testUnreadMatchesEveryVector() throws {
        for vector in try group("unread") {
            let description = (vector["description"] as? String) ?? "unread"
            let broadcast = OperatorBroadcast(
                id: "b", tag: .urgent, title: "t", body: "b",
                createdAtMillis: try XCTUnwrap((vector["broadcast_created_at"] as? NSNumber)?.int64Value)
            )
            let seen = (vector["last_seen_created_at"] as? NSNumber)?.int64Value
            XCTAssertEqual(
                broadcast.isUnread(lastSeenCreatedAtMillis: seen),
                vector["expected_unread"] as? Bool,
                description
            )
        }
    }

    func testAnFcmPayloadOfAllStringsParsesIdenticallyToAFirestoreDocument() {
        // FCM hands every value over as a String; Firestore hands back real numbers. The same
        // broadcast arriving by two routes must produce the same object, or a push and the
        // foreground read of the same row would disagree about what the user was told.
        let fromFirestore = OperatorBroadcast.parse([
            "id": "b1", "tag": "UPDATE", "title": "t", "body": "b",
            "created_at_millis": NSNumber(value: 1_757_000_000_000),
            "applies_to_versions_at_or_below": NSNumber(value: 187),
        ])
        let fromPush = OperatorBroadcast.parse([
            "id": "b1", "tag": "UPDATE", "title": "t", "body": "b",
            "created_at_millis": "1757000000000",
            "applies_to_versions_at_or_below": "187",
        ])
        XCTAssertNotNil(fromPush)
        XCTAssertEqual(fromFirestore, fromPush)
    }

    func testNoUnknownTagCanReachANotificationHoweverItIsSpelled() {
        // The single most important rejection in the contract. A client that lets an unknown tag
        // through will render whatever the next person types into a category box.
        for attempt in ["PROMO", "promo", "Urgent", "URGENT ", " URGENT", "", "MARKETING", "OTHER"] {
            XCTAssertNil(BroadcastTag(rawValue: attempt), attempt)
        }
    }

    func testAVersionCeilingIsRefusedOnEveryTagExceptUpdate() {
        for tag in BroadcastTag.allCases {
            let parsed = OperatorBroadcast.parse([
                "id": "b", "tag": tag.rawValue, "title": "t", "body": "b",
                "created_at_millis": NSNumber(value: 1),
                "applies_to_versions_at_or_below": NSNumber(value: 187),
            ])
            if tag == .update { XCTAssertNotNil(parsed, tag.rawValue) }
            else { XCTAssertNil(parsed, tag.rawValue) }
        }
    }

    func testAnUnreadableBuildNumberIsNeverToldToUpdate() {
        // currentVersionCode() returns Int.max when CFBundleVersion cannot be read, so a
        // version-limited notice never applies. Silence is the safe direction for a message about
        // correctness: telling a device to update to fix a bug it may not have is worse than
        // saying nothing.
        let notice = OperatorBroadcast(
            id: "b", tag: .update, title: "t", body: "b",
            createdAtMillis: 1, appliesToVersionsAtOrBelow: 187
        )
        XCTAssertFalse(notice.applies(toVersionCode: Int.max))
        XCTAssertTrue(notice.applies(toVersionCode: 187))
    }

    // MARK: - The store

    func testTheSameBroadcastArrivingTwiceDoesNotInterruptTwice() {
        // It genuinely arrives twice: once by push, once by the foreground read of the collection.
        let store = BroadcastStore(defaults: isolatedDefaults())
        let broadcast = OperatorBroadcast(id: "a", tag: .urgent, title: "t", body: "b", createdAtMillis: 100)
        XCTAssertTrue(store.store(broadcast))
        XCTAssertFalse(store.store(broadcast))
        XCTAssertEqual(store.broadcasts.count, 1)
    }

    func testABroadcastSurvivesARestart() {
        let defaults = isolatedDefaults()
        BroadcastStore(defaults: defaults)
            .store(OperatorBroadcast(id: "a", tag: .maintenance, title: "Sync is paused", body: "b", createdAtMillis: 100))
        XCTAssertEqual(BroadcastStore(defaults: defaults).broadcasts.map(\.id), ["a"])
    }

    func testTheStoreIsBoundedAndKeepsTheNewest() {
        // Operational messages go stale. An unbounded list turns a preferences file into a log —
        // and dropping the newest would be the wrong direction entirely.
        let store = BroadcastStore(defaults: isolatedDefaults())
        for index in 0..<(BroadcastStore.maxRetained + 5) {
            store.store(OperatorBroadcast(
                id: "b\(index)", tag: .urgent, title: "t", body: "b", createdAtMillis: Int64(index)
            ))
        }
        XCTAssertEqual(store.broadcasts.count, BroadcastStore.maxRetained)
        XCTAssertEqual(store.broadcasts.first?.id, "b24")
    }

    func testUnreadRespectsBothWhatWasSeenAndWhatAppliesToThisBuild() {
        let store = BroadcastStore(defaults: isolatedDefaults())
        store.store(OperatorBroadcast(id: "seen", tag: .urgent, title: "t", body: "b", createdAtMillis: 100))
        store.store(OperatorBroadcast(id: "unseen", tag: .urgent, title: "t", body: "b", createdAtMillis: 300))
        store.store(OperatorBroadcast(
            id: "not-for-this-build", tag: .update, title: "t", body: "b",
            createdAtMillis: 400, appliesToVersionsAtOrBelow: 50
        ))
        store.markSeen(createdAtMillis: 100)
        XCTAssertEqual(store.unread(versionCode: 187).map(\.id), ["unseen"])
    }

    func testMarkSeenNeverMovesBackwards() {
        let store = BroadcastStore(defaults: isolatedDefaults())
        store.markSeen(createdAtMillis: 500)
        store.markSeen(createdAtMillis: 100)
        XCTAssertEqual(store.lastSeenCreatedAtMillis, 500)
    }

    func testAStoredRowThatNoLongerSatisfiesTheContractIsDroppedOnRead() {
        // Re-validated on read rather than trusted because we wrote it. A downgrade, a restore from
        // another build, or a tampered defaults file all land here, and the parser is the only
        // thing between them and the user's lock screen.
        let defaults = isolatedDefaults()
        defaults.set(
            #"[{"id":"x","tag":"PROMO","title":"Half price","body":"b","created_at_millis":1}]"#,
            forKey: "trackme_broadcasts"
        )
        XCTAssertTrue(BroadcastStore(defaults: defaults).broadcasts.isEmpty)
    }

    func testACorruptedDefaultsValueYieldsNothingRatherThanCrashing() {
        let defaults = isolatedDefaults()
        defaults.set("{not json", forKey: "trackme_broadcasts")
        XCTAssertTrue(BroadcastStore(defaults: defaults).broadcasts.isEmpty)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OperatorBroadcastTests.\(UUID().uuidString)")!
    }
}

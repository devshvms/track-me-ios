import XCTest
@testable import track_me_ios

final class GroupSessionStoreRecordTests: XCTestCase {
    func testVersionOneRecordMigratesWithSafeStatusDefaults() throws {
        let legacy = Data(#"""
        {
            "groupId":"g1","joinCode":"ABC123","isLeader":true,
            "expiresAtMillis":1785000000000,"maxMembers":5,"rev":3
        }
        """#.utf8)
        let record = try JSONDecoder().decode(GroupSessionStore.Record.self, from: legacy)
        XCTAssertNil(record.status)
        XCTAssertFalse(record.alertsMuted)
        XCTAssertFalse(record.hasStarted)
        XCTAssertEqual(record.shownAlertStatuses, [:])
    }

    func testStoredStatusPreservesExactEnvelopeAndPendingOperation() throws {
        let status = GroupSessionStore.StoredStatus(
            raw: "1GNH",
            envelope: "byte-identical-envelope",
            setAtElapsedMillis: 123,
            bootEpochAtSetMillis: 456,
            pendingOperation: .set,
            acknowledged: false
        )
        let record = GroupSessionStore.Record(
            groupId: "g", joinCode: "ABC123", isLeader: false,
            expiresAtMillis: 9_999_999_999_999, maxMembers: 5, rev: 2,
            hasStarted: true,
            status: status, alertsMuted: true,
            shownAlertStatuses: ["peer": "1GNH"]
        )
        let decoded = try JSONDecoder().decode(
            GroupSessionStore.Record.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.status?.envelope, "byte-identical-envelope")
        XCTAssertTrue(decoded.hasStarted)
    }
}

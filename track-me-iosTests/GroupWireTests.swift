import CryptoKit
import XCTest
@testable import track_me_ios

final class GroupWireTests: XCTestCase {
    func testInitialsUseFirstAndLastWord() {
        XCTAssertEqual(GroupWire.initials(for: "Jean de Ville"), "JV")
        XCTAssertEqual(GroupWire.initials(for: "Priya"), "P")
        XCTAssertNil(GroupWire.initials(for: "   "))
    }

    func testDestinationMapsURLUsesFixedDecimalLocale() {
        let url = GroupDestinationLinks.appleMapsURL(lat: 12.9716, lng: 77.5946)
        XCTAssertEqual(url?.absoluteString, "http://maps.apple.com/?ll=12.971600,77.594600")
    }

    func testSyncParserAsksForRosterWhenLocalRosterIsEmpty() {
        let emptyRosterState = GroupSessionState(rev: 7, roster: [])
        let populatedRosterState = GroupSessionState(rev: 7, roster: [
            GroupWire.RosterEntry(uid: "uid-a", displayName: "A", initials: "A", photoUrl: nil)
        ])

        XCTAssertEqual(syncRevParameter(for: emptyRosterState), -1)
        XCTAssertEqual(syncRevParameter(for: populatedRosterState), 7)
    }

    func testParseSyncSkipsSelfAndUndecryptableMembers() throws {
        let token = "Zm9vYmFyYmF6cXV4MTIzNA"
        let key = try GroupCrypto.deriveGroupKey(token: token)
        let alicePlain = try GroupWire.encodePosition(
            lat: 12.9716,
            lng: 77.5946,
            speedMps: 4.2,
            headingDeg: 137,
            batteryPercent: 82,
            moving: true,
            riding: true
        )
        let aliceEnvelope = try GroupCrypto.seal(
            key: key,
            plaintext: alicePlain,
            purpose: .position(uid: "uid-alice"),
            nonce: Data(repeating: 7, count: 12)
        )
        let selfEnvelope = try GroupCrypto.seal(
            key: key,
            plaintext: alicePlain,
            purpose: .position(uid: "uid-self"),
            nonce: Data(repeating: 8, count: 12)
        )
        let response: [String: Any] = [
            "state": "LIVE",
            "expiresAt": 1_785_014_400_000,
            "rev": 2,
            "maxMembers": 5,
            "nextSyncInSec": 10,
            "positions": [
                "uid-alice": ["e": aliceEnvelope, "ts": 1_785_000_000_000],
                "uid-self": ["e": selfEnvelope, "ts": 1_785_000_000_000],
                "uid-bad": ["e": aliceEnvelope, "ts": 1_785_000_000_000]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: response)
        let parsed = try GroupWire.parseSync(data, key: key, selfUid: "uid-self")

        XCTAssertEqual(parsed.positions.map(\.uid), ["uid-alice"])
        XCTAssertEqual(parsed.positions.first?.riding, true)
        XCTAssertEqual(parsed.undecryptable, ["uid-bad"])
    }

    private func syncRevParameter(for state: GroupSessionState) -> Int {
        state.roster.isEmpty ? -1 : state.rev
    }
}

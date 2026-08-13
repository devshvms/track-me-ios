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

    func testMemberDirectionsUseRoutePreviewAndFixedDecimalLocale() {
        XCTAssertEqual(
            GroupDestinationLinks.appleDirectionsURL(lat: -33.865143, lng: 151.2099)?.absoluteString,
            "http://maps.apple.com/?daddr=-33.865143,151.209900&dirflg=d"
        )
        XCTAssertEqual(
            GroupDestinationLinks.googleDirectionsURL(lat: -33.865143, lng: 151.2099)?.absoluteString,
            "comgooglemaps://?daddr=-33.865143,151.209900&directionsmode=driving"
        )
    }

    func testStateParserCarriesRestartedClockAndAtomicMetaAcknowledgement() throws {
        let key = try GroupCrypto.deriveGroupKey(token: "Zm9vYmFyYmF6cXV4MTIzNA")
        let meta = try GroupCrypto.seal(
            key: key,
            plaintext: try GroupWire.encodeMeta(
                name: "Sunday Riders",
                ownerDisplayName: "Rider",
                destLat: nil,
                destLng: nil,
                startAtMillis: 1_785_000_000_000
            ),
            purpose: .meta
        )
        let response: [String: Any] = [
            "groupId": "group-id",
            "state": "LIVE",
            "expiresAt": 1_785_014_400_000,
            "rev": 8,
            "metaUpdated": true,
            "meta": meta
        ]

        let parsed = try GroupWire.parseState(
            JSONSerialization.data(withJSONObject: response),
            key: key
        )

        XCTAssertEqual(parsed.state, "LIVE")
        XCTAssertEqual(parsed.expiresAtMillis, 1_785_014_400_000)
        XCTAssertEqual(parsed.rev, 8)
        XCTAssertTrue(parsed.metaUpdated)
        XCTAssertEqual(parsed.meta?.startAtMillis, 1_785_000_000_000)
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
            "serverNow": 1_785_000_005_000,
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
        XCTAssertEqual(parsed.positions.first?.ageAnchor?.ageAtReceiptMillis, 5_000)
        XCTAssertEqual(parsed.selfPositionAck?.envelope, selfEnvelope)
        XCTAssertEqual(parsed.undecryptable, ["uid-bad"])
    }

    func testStatusSlotUsesSeparateAADAndSkewImmuneAge() throws {
        let key = try GroupCrypto.deriveGroupKey(token: "Zm9vYmFyYmF6cXV4MTIzNA")
        let statusPlain = try GroupWire.encodeStatus(
            try XCTUnwrap(RiderStatusCodec.parse("1GNH")),
            statusAgeSeconds: 420
        )
        let envelope = try GroupCrypto.seal(
            key: key,
            plaintext: statusPlain,
            purpose: .status(uid: "uid-alice"),
            nonce: Data(repeating: 9, count: 12)
        )
        let response: [String: Any] = [
            "state": "LIVE",
            "expiresAt": 1_785_014_400_000,
            "rev": 2,
            "maxMembers": 5,
            "nextSyncInSec": 10,
            "serverNow": 1_785_000_005_000,
            "positions": [:],
            "statuses": [
                "uid-alice": ["e": envelope, "ts": 1_785_000_003_000]
            ]
        ]

        let parsed = try GroupWire.parseSync(
            JSONSerialization.data(withJSONObject: response),
            key: key,
            selfUid: "uid-self"
        )

        XCTAssertTrue(parsed.statusesFieldPresent)
        XCTAssertEqual(parsed.statuses.first?.status.raw, "1GNH")
        XCTAssertEqual(parsed.statuses.first?.ageAnchor.ageAtReceiptMillis, 422_000)
        XCTAssertThrowsError(try GroupCrypto.open(
            key: key,
            envelope: envelope,
            purpose: .position(uid: "uid-alice")
        ))
        XCTAssertLessThanOrEqual(envelope.count, 256)
    }

    func testMissingServerNowUsesLegacyWallClockFallback() throws {
        let key = try GroupCrypto.deriveGroupKey(token: "Zm9vYmFyYmF6cXV4MTIzNA")
        let plain = try GroupWire.encodePosition(
            lat: 1, lng: 2, speedMps: nil, headingDeg: nil,
            batteryPercent: nil, moving: false, riding: false
        )
        let envelope = try GroupCrypto.seal(key: key, plaintext: plain, purpose: .position(uid: "peer"))
        let response: [String: Any] = [
            "positions": ["peer": ["e": envelope, "ts": 1]],
            "nextSyncInSec": 10
        ]
        let parsed = try GroupWire.parseSync(
            JSONSerialization.data(withJSONObject: response),
            key: key,
            selfUid: "self",
            legacyWallNowMillis: 5_001
        )
        XCTAssertEqual(parsed.positions.first?.ageAnchor?.isKnown, true)
        XCTAssertEqual(parsed.positions.first?.ageAnchor?.ageAtReceiptMillis, 5_000)
    }

    func testMalformedStatusIsReportedAsUnreadableRatherThanAValidClear() throws {
        let key = try GroupCrypto.deriveGroupKey(token: "Zm9vYmFyYmF6cXV4MTIzNA")
        let malformed = try GroupCrypto.seal(
            key: key,
            plaintext: #"{"st":"not-a-status"}"#,
            purpose: .status(uid: "peer")
        )
        let response: [String: Any] = [
            "serverNow": 1_785_000_005_000,
            "positions": [:],
            "statuses": ["peer": ["e": malformed, "ts": 1_785_000_003_000]],
            "nextSyncInSec": 10
        ]

        let parsed = try GroupWire.parseSync(
            JSONSerialization.data(withJSONObject: response), key: key, selfUid: "self"
        )
        XCTAssertTrue(parsed.statuses.isEmpty)
        XCTAssertEqual(parsed.unreadableStatusUIDs, ["peer"])
    }

    func testStatusRequestUsesCanonicalContractFieldNames() {
        let set = GroupWire.statusRequestFields(for: .set(envelope: "v1.nonce.body"))
        XCTAssertEqual(set["statusOp"] as? String, "set")
        XCTAssertEqual(set["status"] as? String, "v1.nonce.body")
        XCTAssertNil(set["statusField"])

        let clear = GroupWire.statusRequestFields(for: .clear)
        XCTAssertEqual(clear["statusOp"] as? String, "clear")
        XCTAssertNil(clear["status"])
    }

    private func syncRevParameter(for state: GroupSessionState) -> Int {
        state.roster.isEmpty ? -1 : state.rev
    }
}

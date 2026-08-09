import CryptoKit
import XCTest
@testable import track_me_ios

final class GroupCryptoTests: XCTestCase {
    func testHKDFMatchesRFC5869Case1() throws {
        let ikm = Data(hexString: String(repeating: "0b", count: 22))!
        let salt = Data(hexString: "000102030405060708090a0b0c")!
        let info = Data(hexString: "f0f1f2f3f4f5f6f7f8f9")!
        let key = GroupCrypto.hkdf(ikm: ikm, info: info, length: 42, salt: salt)

        XCTAssertEqual(
            key.data.hexString,
            "3cb25f25faacd57a90434f64d0362f2a" +
            "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
            "34007208d5b887185865"
        )
    }

    func testSharedGroupCryptoVectors() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, GroupCrypto.envelopeVersion)

        for testCase in fixture.cases {
            let key = try GroupCrypto.deriveGroupKey(token: testCase.token)
            XCTAssertEqual(key.data.hexString, testCase.keyHex, testCase.name)
            XCTAssertEqual(try GroupCrypto.groupTokenHash(testCase.token), testCase.tokenHashHex, testCase.name)

            let purpose = purpose(named: testCase.purpose, uid: testCase.memberUid)
            let nonce = GroupCrypto.base64UrlDecode(testCase.nonceB64Url)!
            XCTAssertEqual(
                try GroupCrypto.seal(
                    key: key,
                    plaintext: testCase.plaintext,
                    purpose: purpose,
                    nonce: nonce
                ),
                testCase.envelope,
                testCase.name
            )
            XCTAssertEqual(
                try GroupCrypto.open(key: key, envelope: testCase.envelope, purpose: purpose),
                testCase.plaintext,
                testCase.name
            )
        }
    }

    func testCodeWrappingVectors() throws {
        let fixture = try loadFixture()
        for testCase in fixture.codeCases {
            let key = try GroupCrypto.deriveCodeKey(joinCode: testCase.joinCode)
            XCTAssertEqual(key.data.hexString, testCase.codeKeyHex, testCase.name)
            let nonce = GroupCrypto.base64UrlDecode(testCase.nonceB64Url)!
            XCTAssertEqual(
                try GroupCrypto.wrapTokenForCode(
                    joinCode: testCase.joinCode,
                    token: testCase.inviteToken,
                    nonce: nonce
                ),
                testCase.wrappedToken,
                testCase.name
            )
            XCTAssertEqual(
                try GroupCrypto.unwrapTokenWithCode(joinCode: testCase.joinCode, wrapped: testCase.wrappedToken),
                testCase.inviteToken,
                testCase.name
            )
        }
    }

    func testAssociatedDataRejectsSlotSwap() throws {
        let fixture = try loadFixture()
        let positionCase = try XCTUnwrap(fixture.cases.first { $0.purpose == "pos" && $0.memberUid == "uid-alice" })
        let key = try GroupCrypto.deriveGroupKey(token: positionCase.token)

        XCTAssertThrowsError(
            try GroupCrypto.open(
                key: key,
                envelope: positionCase.envelope,
                purpose: .position(uid: "uid-bob")
            )
        )
    }

    func testJoinCodeNormalization() {
        XCTAssertEqual(GroupCrypto.normalizeJoinCode("ab c-12o"), "ABC120")
        XCTAssertEqual(GroupCrypto.normalizeJoinCode("il0u00"), nil)
        XCTAssertNil(GroupCrypto.normalizeJoinCode("ABC12"))
    }

    private func purpose(named name: String, uid: String?) -> GroupCrypto.Purpose {
        switch name {
        case "meta":
            return .meta
        case "roster":
            return .roster(uid: uid!)
        case "pos":
            return .position(uid: uid!)
        default:
            XCTFail("Unknown purpose \(name)")
            return .meta
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/group-crypto-vectors.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }
}

private struct Fixture: Decodable {
    let version: String
    let cases: [CryptoCase]
    let codeCases: [CodeCase]
}

private struct CryptoCase: Decodable {
    let name: String
    let token: String
    let tokenHashHex: String
    let keyHex: String
    let purpose: String
    let memberUid: String?
    let plaintext: String
    let nonceB64Url: String
    let envelope: String
}

private struct CodeCase: Decodable {
    let name: String
    let joinCode: String
    let codeKeyHex: String
    let inviteToken: String
    let nonceB64Url: String
    let wrappedToken: String
}

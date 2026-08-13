import XCTest
@testable import track_me_ios

final class GroupStatusFixtureTests: XCTestCase {
    func testCanonicalStatusGrammarFallbacksAndAges() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.canonical, "track-me-web/tests/fixtures — copy to each client, same as group-crypto-vectors.json")
        XCTAssertEqual(fixture.grammar, #"^[0-9][A-Z][A-Z]{2}(:[A-Za-z0-9]{1,8})?$"#)

        for vector in fixture.codes {
            let parsed = RiderStatusCodec.parse(vector.raw)
            guard vector.valid else {
                XCTAssertNil(parsed, vector.note ?? vector.raw)
                continue
            }

            let status = try XCTUnwrap(parsed, vector.note ?? vector.raw)
            XCTAssertEqual(String(status.severity.rawValue), vector.severity, vector.raw)
            XCTAssertEqual(status.persona.map { String($0.rawValue) }, vector.persona, vector.raw)
            XCTAssertEqual(status.message, vector.message, vector.raw)
            XCTAssertEqual(status.extensionValue, vector.extensionValue, vector.raw)
        }

        for vector in fixture.ages {
            let anchor = StatusAge.anchorStatus(
                serverNowMillis: vector.serverNowMs,
                serverTimestampMillis: vector.serverTsMs,
                statusAgeSeconds: vector.stAgeSeconds,
                receivedAtElapsedMillis: 123_000
            )
            if let expected = vector.expectedAgeAtReceiptMs {
                XCTAssertTrue(anchor.isKnown, vector.note)
                XCTAssertEqual(anchor.ageAtReceiptMillis, expected, vector.note)
            } else {
                XCTAssertFalse(anchor.isKnown, vector.note)
            }
        }

        for vector in fixture.buckets {
            let bucket = StatusAge.bucket(ageMillis: vector.ageMs, syncIntervalSec: vector.syncIntervalSec)
            XCTAssertEqual(fixtureValue(for: bucket), vector.expected, vector.note ?? vector.expected)
        }
    }

    private func fixtureValue(for bucket: StatusAge.Bucket) -> String {
        switch bucket {
        case .now: "Now"
        case .seconds(let value): "Seconds:\(value)"
        case .minutes(let value): "Minutes:\(value)"
        case .hours(let value): "Hours:\(value)"
        case .unknown: "Unknown"
        }
    }

    private func loadFixture() throws -> GroupStatusFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/group-status-vectors.json")
        return try JSONDecoder().decode(GroupStatusFixture.self, from: Data(contentsOf: url))
    }
}

private struct GroupStatusFixture: Decodable {
    let version: Int
    let canonical: String
    let grammar: String
    let codes: [GroupStatusCodeCase]
    let ages: [GroupStatusAgeCase]
    let buckets: [GroupStatusBucketCase]
}

private struct GroupStatusCodeCase: Decodable {
    let raw: String
    let valid: Bool
    let severity: String?
    let persona: String?
    let message: String?
    let extensionValue: String?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case raw, valid, severity, persona, message, note
        case extensionValue = "extension"
    }
}

private struct GroupStatusAgeCase: Decodable {
    let note: String
    let serverNowMs: Int64
    let serverTsMs: Int64
    let stAgeSeconds: Int64?
    let expectedAgeAtReceiptMs: Int64?
}

private struct GroupStatusBucketCase: Decodable {
    let ageMs: Int64
    let syncIntervalSec: Int
    let expected: String
    let note: String?
}

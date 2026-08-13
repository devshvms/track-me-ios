import XCTest
@testable import track_me_ios

final class RiderStatusTests: XCTestCase {
    func testGrammarAndExtension() throws {
        let status = try XCTUnwrap(RiderStatusCodec.parse("2MEH:T15"))
        XCTAssertEqual(status.code, "2MEH")
        XCTAssertEqual(status.severity, .caution)
        XCTAssertEqual(status.persona, .bikeDrive)
        XCTAssertEqual(status.message, "EH")
        XCTAssertEqual(status.extensionValue, "T15")
        XCTAssertEqual(status.raw, "2MEH:T15")
    }

    func testMalformedValuesAreIgnored() {
        [nil, "", "2ME", "2MEHX", "2meh", "2MEH:", "2MEH:!!", "2MEH:TOOLONGEXT"].forEach {
            XCTAssertNil(RiderStatusCodec.parse($0))
        }
    }

    func testUnknownValuesDegradeSafely() throws {
        let unknownMessage = try XCTUnwrap(RiderStatusCodec.parse("2MOH"))
        XCTAssertEqual(unknownMessage.severity, .caution)
        XCTAssertEqual(unknownMessage.persona, .bikeDrive)
        XCTAssertFalse(unknownMessage.isKnown)

        let unknownPersona = try XCTUnwrap(RiderStatusCodec.parse("1ZNH"))
        XCTAssertEqual(unknownPersona.severity, .alert)
        XCTAssertNil(unknownPersona.persona)

        for code in ["4GNH", "9GNH"] {
            XCTAssertEqual(RiderStatusCodec.parse(code)?.severity, .info)
        }
    }

    func testReservedTierZeroFailsQuietToInfoEvenThoughItSortsAboveAlert() throws {
        let status = try XCTUnwrap(RiderStatusCodec.parse("0GNH"))

        XCTAssertEqual(status.severity, .info)
        XCTAssertFalse(status.isAlert)
        XCTAssertEqual(RiderStatusPresentation.systemImage(status.severity), "circle.fill")
    }

    func testCatalogOffersFourToSixOptionsWithAlertsLast() {
        for persona in StatusPersona.allCases.map(Optional.some) + [nil] {
            let options = RiderStatusCatalog.options(for: persona)
            XCTAssertTrue((4...6).contains(options.count))
            XCTAssertLessThanOrEqual(options.filter(\.isAlert).count, 2)
            XCTAssertEqual(options.map(\.severity), options.map(\.severity).sorted(by: >))
            XCTAssertTrue(options.allSatisfy(\.isKnown))
        }
    }

    func testCrashedRemainsDecodableButIsNotSelectable() throws {
        XCTAssertEqual(try XCTUnwrap(RiderStatusCodec.parse(RiderStatusCatalog.crashed)).severity, .alert)

        for persona in StatusPersona.allCases.map(Optional.some) + [nil] {
            XCTAssertFalse(RiderStatusCatalog.options(for: persona).contains { $0.code == RiderStatusCatalog.crashed })
        }
    }
}

import XCTest
@testable import track_me_ios

/// The §4.4 disclosure table, asserted row by row — the iOS mirror of Android's
/// `VoiceGroupAnswersTest`. These two must stay in lockstep: a rider in a mixed-platform group must
/// not get different confidence about the same fact depending on whose phone answered.
final class VoiceGroupAnswersTests: XCTestCase {

    private func member(_ name: String?, _ freshness: VoiceFreshness, key: String? = nil) -> VoiceGroupMemberFact {
        VoiceGroupMemberFact(cacheKey: key ?? (name ?? ""), displayName: name, freshness: freshness)
    }

    // MARK: - §4.4 disclosure table

    func testFreshFixWithVouchableHeadingIsTheOnlyCaseThatEarnsADirection() {
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .now, distanceMeters: 500, direction: .ahead, headingIsVouchable: true
        )
        XCTAssertEqual(d, .distanceAndDirection(roundedMeters: 500, direction: .ahead))
    }

    func testFreshFixWithoutVouchableHeadingGivesDistanceButNoDirection() {
        // The heading gate is false when the member is stationary or auto-paused: a trail behind a
        // parked rider reads as movement that is not happening.
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .now, distanceMeters: 500, direction: .ahead, headingIsVouchable: false
        )
        XCTAssertEqual(d, .distanceWithAge(roundedMeters: 500, freshness: .now))
    }

    func testSecondsAndMinutesGiveDistanceWithAgeNeverADirection() {
        for fresh in [VoiceFreshness.seconds(40), VoiceFreshness.minutes(2)] {
            let d = VoiceGroupAnswers.discloseMember(
                freshness: fresh, distanceMeters: 500, direction: .ahead, headingIsVouchable: true
            )
            XCTAssertEqual(d, .distanceWithAge(roundedMeters: 500, freshness: fresh), "\(fresh) must not earn a direction")
        }
    }

    func testTheArchitectureContractsOwnExampleLineIsNotImplementable() {
        // "Alice's last known location from 2 minutes ago was 500 meters ahead of you" — the
        // direction half of that sentence cannot be produced by any input.
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .minutes(2), distanceMeters: 500, direction: .ahead, headingIsVouchable: true
        )
        if case .distanceAndDirection = d { XCTFail("a two-minute-old fix must never carry a direction") }
    }

    func testHoursOldWithholdsTheDistanceEntirely() {
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .hours(1), distanceMeters: 500, direction: .ahead, headingIsVouchable: true
        )
        XCTAssertEqual(d, .ageOnly(freshness: .hours(1)))
    }

    func testUnknownAgeNeverProducesANumber() {
        // The sender rebooted; the age is unrecoverable. Speak presence, never a guessed age.
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .unknown, distanceMeters: 500, direction: .ahead, headingIsVouchable: true
        )
        XCTAssertEqual(d, .presenceOnly)
    }

    func testNoCachedPositionDisclosesPresenceOnly() {
        let d = VoiceGroupAnswers.discloseMember(
            freshness: .now, distanceMeters: nil, direction: nil, headingIsVouchable: true
        )
        XCTAssertEqual(d, .presenceOnly)
    }

    // MARK: - §4.3 rounding (must match Android exactly)

    func testUnderAKilometreRoundsToFiftyMetres() {
        XCTAssertEqual(VoiceGroupAnswers.roundDistanceMeters(487), 500)
        XCTAssertEqual(VoiceGroupAnswers.roundDistanceMeters(462), 450)
        XCTAssertEqual(VoiceGroupAnswers.roundDistanceMeters(12), 0)
    }

    func testAboveAKilometreRoundsToOneDecimal() {
        XCTAssertEqual(VoiceGroupAnswers.roundDistanceMeters(6_284), 6_300)
        XCTAssertEqual(VoiceGroupAnswers.roundDistanceMeters(1_004), 1_000)
    }

    // MARK: - §4.6 name matching

    func testExactMatchIgnoresCaseAndDiacritics() {
        let alice = member("Alice", .now)
        XCTAssertEqual(VoiceGroupAnswers.matchName("alice", members: [alice, member("Bob", .now)]), .matched(alice))

        let chloe = member("Chloé", .now)
        XCTAssertEqual(VoiceGroupAnswers.matchName("chloe", members: [chloe]), .matched(chloe))
    }

    func testUniquePrefixMatches() {
        let alice = member("Alice", .now)
        XCTAssertEqual(
            VoiceGroupAnswers.matchName("Ali", members: [alice, member("Bob", .now)]),
            .matched(alice)
        )
    }

    func testTwoCandidatesAskRatherThanGuess() {
        let alice = member("Alice", .now)
        let alex = member("Alex", .now)
        guard case .ambiguous(let candidates) = VoiceGroupAnswers.matchName("Al", members: [alice, alex]) else {
            return XCTFail("two candidates must be ambiguous")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testDuplicateDisplayNamesAreAmbiguousNeverASilentPick() {
        let a1 = member("Alex", .now, key: "k1")
        let a2 = member("Alex", .now, key: "k2")
        guard case .ambiguous = VoiceGroupAnswers.matchName("Alex", members: [a1, a2]) else {
            return XCTFail("duplicate names must never resolve silently")
        }
    }

    func testUnknownNameDoesNotMatchAnyone() {
        XCTAssertEqual(VoiceGroupAnswers.matchName("Zara", members: [member("Alice", .now)]), .noMatch)
        XCTAssertEqual(VoiceGroupAnswers.matchName("   ", members: [member("Alice", .now)]), .noMatch)
    }

    func testMembersWithNoDisplayNameAreNeverMatched() {
        XCTAssertEqual(VoiceGroupAnswers.matchName("alice", members: [member(nil, .now, key: "k")]), .noMatch)
    }

    // MARK: - §4.5 roster

    func testAlertsComeOnlyFromADeclaredStatus() {
        let bob = member("Bob", .minutes(3))
        let alice = member("Alice", .now)
        let answer = VoiceGroupAnswers.roster(connection: .current, members: [alice, bob]) { $0.displayName == "Bob" }
        XCTAssertEqual(answer.alerts, [bob])
        XCTAssertEqual(answer.memberCount, 2)
    }

    func testMovementNeverBecomesAnAlertAndNeverBecomesReassurance() {
        // Four moving riders with no declared status must yield zero alerts — the roster reports
        // what people said, not what their dots did.
        let movers = (1...4).map { member("R\($0)", .now, key: "k\($0)") }
        let answer = VoiceGroupAnswers.roster(connection: .current, members: movers) { _ in false }
        XCTAssertTrue(answer.alerts.isEmpty)
        XCTAssertEqual(answer.recentlyHeardCount, 4)
        XCTAssertTrue(answer.notHeardFrom.isEmpty)
    }

    func testStaleAndAgeUnknownMembersAreReportedAsNotHeardFrom() {
        let fresh = member("Alice", .now)
        let old = member("Bob", .hours(1))
        let rebooted = member("Cara", .unknown)
        let answer = VoiceGroupAnswers.roster(connection: .current, members: [fresh, old, rebooted]) { _ in false }
        XCTAssertEqual(answer.recentlyHeardCount, 1)
        XCTAssertEqual(answer.notHeardFrom, [old, rebooted])
    }

    func testDegradedConnectionIsCarriedSoItCanBeSaidAloud() {
        let answer = VoiceGroupAnswers.roster(connection: .degraded, members: [member("A", .now)]) { _ in false }
        XCTAssertEqual(answer.connection, .degraded)
    }
}

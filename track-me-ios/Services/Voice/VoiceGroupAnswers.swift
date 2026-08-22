import Foundation

/// What voice is allowed to say about another rider — SCOPE_1.8.4 §4.3–§4.6, TASK-195.
///
/// ### The rule this file exists to enforce
///
/// **A spoken answer may never claim more confidence than the underlying fix supports.** The map
/// already refuses these claims twice, in shipped code: the member-directions action is *absent*,
/// not disabled, for a stale member — a two-minute-old fix is kilometres wrong at road speed — and
/// the heading tail is not drawn when a member is stale, stationary, or auto-paused, because a
/// fading trail is a claim about recent motion we can only make when we can vouch for it.
///
/// Voice has to refuse *harder* than the map, because it has nowhere to show doubt. A greyed chip
/// beside a distance tells the reader the number is old; a sentence spoken over road noise does not.
///
/// ### Parity
///
/// A direct mirror of Android's `VoiceGroupAnswers.kt`: identical thresholds, identical rounding,
/// identical refusals. The two must not drift — a rider in a mixed-platform group would otherwise
/// get different confidence about the same fact depending on whose phone answered.
///
/// Pure: no clock, no network, no formatting. Freshness arrives already bucketed (never re-derived
/// from a device clock), distance and bearing arrive already computed, and the caller renders the
/// result through the `voice*` catalogue.

/// Where a member is relative to the listener, when that may be claimed at all.
nonisolated enum VoiceDirection: Equatable {
    case ahead
    case behind
    /// Close enough that "ahead" and "behind" would both be noise.
    case nearby
}

/// How much may be disclosed about one member's position. Ordered most to least confident.
///
/// Nothing here carries a coordinate: §4 forbids voice ever speaking one, and making that a property
/// of the type rather than of a call site is what keeps it true.
nonisolated enum VoiceMemberDisclosure: Equatable {
    /// Fresh fix and a vouchable heading: distance *and* direction.
    case distanceAndDirection(roundedMeters: Int, direction: VoiceDirection)
    /// Fresh enough for a distance, not for a direction. The age is spoken with it.
    case distanceWithAge(roundedMeters: Int, freshness: VoiceFreshness)
    /// Too old for a number at all — the age alone. An hour-old position names a place they have left.
    case ageOnly(freshness: VoiceFreshness)
    /// In the group, but nothing about their position may be claimed. Never a guessed age.
    case presenceOnly
}

/// The result of matching a spoken name against the roster — §4.6.
nonisolated enum VoiceNameMatch: Equatable {
    case matched(VoiceGroupMemberFact)
    /// Two or more plausible riders. Voice asks rather than picking one.
    case ambiguous([VoiceGroupMemberFact])
    case noMatch
}

/// What "who's in my group?" / "is everyone okay?" may report.
///
/// `alerts` is derived **only** from a declared severity-1 status. There is deliberately no
/// "everyone looks fine" signal computed from movement: inferring safety from moving dots is a claim
/// the product cannot support, on the question where being wrong costs the most.
nonisolated struct VoiceRosterAnswer: Equatable {
    let memberCount: Int
    let alerts: [VoiceGroupMemberFact]
    let recentlyHeardCount: Int
    let notHeardFrom: [VoiceGroupMemberFact]
    let connection: VoiceGroupConnection
}

nonisolated enum VoiceGroupAnswers {

    /// Under a kilometre reads in fifty-metre steps; "four hundred and eighty-seven" is a machine talking.
    static let nearRoundingMeters = 50
    static let kilometre = 1_000.0

    /// The §4.4 disclosure table, and the only place it is decided.
    ///
    /// - Parameters:
    ///   - headingIsVouchable: the caller's heading-tail gate for this member. False when they are
    ///     stationary, auto-paused, stale, or have too few samples to imply a direction.
    static func discloseMember(
        freshness: VoiceFreshness,
        distanceMeters: Double?,
        direction: VoiceDirection?,
        headingIsVouchable: Bool
    ) -> VoiceMemberDisclosure {
        // Age we cannot vouch for outranks everything: without a known age, a distance is a number
        // with no scale on it.
        if case .unknown = freshness { return .presenceOnly }
        if case .hours = freshness { return .ageOnly(freshness: freshness) }
        guard let meters = distanceMeters, !meters.isNaN, meters >= 0 else { return .presenceOnly }

        let rounded = roundDistanceMeters(meters)
        // A direction word requires BOTH a fix from this sync interval and a heading the map itself
        // would draw. Either alone is not enough.
        if case .now = freshness, headingIsVouchable, let direction {
            return .distanceAndDirection(roundedMeters: rounded, direction: direction)
        }
        return .distanceWithAge(roundedMeters: rounded, freshness: freshness)
    }

    /// Rounds the way a rider thinks: fifty-metre steps under a kilometre, one decimal above.
    ///
    /// Returns metres in both cases; the catalogue decides whether to speak "six point three
    /// kilometres" or "five hundred metres", because that choice is locale-shaped and this is not.
    static func roundDistanceMeters(_ meters: Double) -> Int {
        if meters < kilometre {
            return Int((meters / Double(nearRoundingMeters)).rounded()) * nearRoundingMeters
        }
        return Int((meters / 100.0).rounded()) * 100
    }

    /// Matches a spoken name against the roster — §4.6.
    ///
    /// Display names are user data: non-Latin scripts, emoji, duplicates, and nicknames an assistant
    /// will never transcribe cleanly. Exact match first, then a *unique* prefix; two candidates ask
    /// rather than guess. Never silently answer about the wrong rider.
    static func matchName(_ spoken: String, members: [VoiceGroupMemberFact]) -> VoiceNameMatch {
        let needle = normalise(spoken)
        guard !needle.isEmpty else { return .noMatch }

        let named = members.filter { !($0.displayName ?? "").isEmpty }
        let exact = named.filter { normalise($0.displayName!) == needle }
        if exact.count == 1 { return .matched(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        let prefixed = named.filter { normalise($0.displayName!).hasPrefix(needle) }
        if prefixed.count == 1 { return .matched(prefixed[0]) }
        if prefixed.count > 1 { return .ambiguous(prefixed) }
        return .noMatch
    }

    /// Case- and diacritic-insensitive comparison key, folded against a fixed locale.
    ///
    /// Fixed locale deliberately: a Turkish device lowercasing "I" to "ı" would stop a rider called
    /// Ian from matching — the same class of trap as a comma decimal separator in a maps URL.
    private static func normalise(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Builds the roster answer.
    ///
    /// - Parameter isAlert: whether this member has a **declared** severity-1 status. Nothing is
    ///   inferred from position or movement.
    static func roster(
        connection: VoiceGroupConnection,
        members: [VoiceGroupMemberFact],
        isAlert: (VoiceGroupMemberFact) -> Bool
    ) -> VoiceRosterAnswer {
        let alerts = members.filter(isAlert)
        let heardRecently = members.filter {
            if case .now = $0.freshness { return true }
            if case .seconds = $0.freshness { return true }
            return false
        }.count
        let notHeard = members.filter {
            if case .hours = $0.freshness { return true }
            if case .unknown = $0.freshness { return true }
            return false
        }
        return VoiceRosterAnswer(
            memberCount: members.count,
            alerts: alerts,
            recentlyHeardCount: heardRecently,
            notHeardFrom: notHeard,
            connection: connection
        )
    }
}

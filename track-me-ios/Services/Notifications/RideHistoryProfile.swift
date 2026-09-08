import Foundation

/// SCOPE_1.8.7 §6.1.3 scenario 12a and §6.1.2 scenario 10b — what the app may infer from someone's
/// own history, and when it must admit it does not know.
///
/// ### This is the file where #12 became #12a
///
/// Scenario 12 — inferring a routine from movement history and *acting* on it unasked — was cut.
/// §4.2 N3 is the reason: it is the surveillance read, and the one thing a privacy-first tracker
/// cannot be caught doing. 12a keeps the same inference and changes who decides. The app says
/// "Saturday, 8:00 — is that right?" and the user answers. Nothing is scheduled until they do.
///
/// That difference only survives if the suggestion is *visibly* a guess and is withheld when it
/// would be a bad one. A confidently wrong "you usually ride Tuesday 7am" is worse than no
/// suggestion at all: it is the app demonstrating both that it watches and that it misreads. So
/// every derivation here fails closed — no pattern, no suggestion, and the settings screen simply
/// shows empty fields the user fills in themselves.
///
/// ### Why the caller supplies day and hour
///
/// ``Sample`` carries the weekday and hour rather than a timestamp. Deriving those needs a calendar
/// and a timezone, and a policy that reaches for the device clock cannot be tested at the
/// boundaries that matter. `RideHistoryProfileSource` owns the conversion; this owns the judgement.
///
/// The Android twin is `RideHistoryProfile.kt`; both are proved against
/// `ride-history-profile-v1.json`.
enum RideHistoryProfile {

    /// Below this there is no history to speak of, only a coincidence.
    ///
    /// Five rides is roughly a month of a once-a-week rider. Two rides on the same weekday is a
    /// pattern to a computer and an accident to a person, and this file exists to keep the app on
    /// the person's side of that distinction.
    static let minRidesForSuggestion = 5

    /// The modal weekday must carry at least this share of the rides.
    ///
    /// Someone who rides seven days a week has no "usual day", and picking their most frequent one
    /// is picking noise. At 30% a suggestion needs roughly double the share a uniform week would
    /// give any single day.
    static let minDominantDayShare = 0.30

    /// A weekday needs at least two rides before an hour drawn from it means anything.
    static let minRidesOnDominantDay = 2

    /// One recorded ride.
    ///
    /// - Parameters:
    ///   - dayOfWeek: ISO-8601: 1 = Monday … 7 = Sunday. Chosen over `Foundation`'s own numbering,
    ///     which makes Sunday 1 — a shared vector written against either would be a trap for the
    ///     other platform, since `java.util.Calendar` agrees with Foundation and not with ISO.
    ///   - activeMinutes: moving time, not elapsed. A ride that spent an hour at a café is not an
    ///     hour-long ride, and using elapsed time would tell scenario 10b that every ride crosses
    ///     every threshold.
    struct Sample: Equatable {
        let dayOfWeek: Int
        let hour: Int
        let activeMinutes: Int64
        let persona: String

        init(dayOfWeek: Int, hour: Int, activeMinutes: Int64, persona: String) {
            self.dayOfWeek = dayOfWeek
            self.hour = hour
            self.activeMinutes = activeMinutes
            self.persona = persona
        }
    }

    /// A slot worth offering, or nil when the history does not support one.
    ///
    /// - Parameter rideCount: how many rides the suggestion rests on. Surfaced so the UI can say
    ///   what it is based on — "suggested from your last 12 rides" is a courtesy, "suggested for
    ///   you" is a claim the app has not earned.
    struct SuggestedSlot: Equatable {
        let dayOfWeek: Int
        let hour: Int
        let persona: String
        let rideCount: Int
    }

    /// Scenario 12a's suggested slot, derived from the rider's own history.
    ///
    /// Returns nil — meaning "offer an empty form" — whenever the evidence is thin, the week is
    /// flat, or the chosen day is carried by a single ride.
    static func suggestSlot(_ samples: [Sample]) -> SuggestedSlot? {
        guard samples.count >= minRidesForSuggestion else { return nil }

        let byDay = Dictionary(grouping: samples, by: \.dayOfWeek)
        // Ties break toward the earlier weekday rather than by dictionary order: a dictionary's
        // ordering is not a fact about the rider, and a suggestion that changes between two runs
        // over identical history is a suggestion nobody can trust.
        guard let dominantDay = byDay.sorted(by: {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }).first else { return nil }

        let onDay = dominantDay.value
        guard onDay.count >= minRidesOnDominantDay else { return nil }
        guard Double(onDay.count) / Double(samples.count) >= minDominantDayShare else { return nil }

        // The hour comes from that day's rides only. A rider whose Saturday ride is at 08:00 and
        // whose midweek rides are at 19:00 gets "Saturday, 8:00" — averaging across the week would
        // produce an hour they have never once ridden at.
        guard let hour = Dictionary(grouping: onDay, by: \.hour).sorted(by: {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }).first?.key else { return nil }

        guard let persona = dominantPersona(onDay) else { return nil }

        return SuggestedSlot(
            dayOfWeek: dominantDay.key,
            hour: hour,
            persona: persona,
            rideCount: samples.count
        )
    }

    /// The most-ridden persona, ties broken alphabetically so the answer is stable.
    static func dominantPersona(_ samples: [Sample]) -> String? {
        guard !samples.isEmpty else { return nil }
        return Dictionary(grouping: samples, by: \.persona).sorted(by: {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }).first?.key
    }

    /// Median active minutes for `persona`, or across all rides when that persona has too little
    /// history of its own.
    ///
    /// Median rather than mean: one forgotten ride that recorded for six hours would drag a mean
    /// far enough to make scenario 10b promise a level the rider will not reach today. Scenario 4
    /// exists precisely because such rides happen, so the statistic that feeds another feature has
    /// to be the one that shrugs them off.
    static func typicalActiveMinutes(_ samples: [Sample], persona: String?) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let forPersona = persona.map { p in samples.filter { $0.persona == p } } ?? []
        // Falling back to all personas is deliberate. A rider with forty runs and one first-ever
        // cycle should still get a sane estimate on that first cycle; refusing to answer would
        // silently disable 10b for exactly the ride where a new level is most likely.
        let pool = forPersona.count >= minRidesOnDominantDay ? forPersona : samples
        let sorted = pool.map(\.activeMinutes).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        // Rounds down on the even case. Under-promising is the correct direction of error for
        // every consumer of this number.
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}

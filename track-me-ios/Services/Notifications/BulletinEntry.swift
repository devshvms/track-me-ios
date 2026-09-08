import Foundation

/// SCOPE_1.8.7 §6.1.7 scenario 32 — the in-app bulletin, and the release's backbone.
///
/// The iOS twin of `domain/bulletin/BulletinEntry.kt`.
///
/// §6.0 caps proactive notifications at one per seven days. That cap is survivable — rather than
/// limiting — only because everything it refuses has somewhere else to go. The bulletin is that
/// somewhere: levels, milestones, recaps, sync problems, exports, version notes, and a copy of
/// every notification actually sent.
///
/// ### Why entries store facts, not sentences
///
/// Storing the finished text is obvious and wrong here: TrackMe ships in seven languages and lets
/// people change language in the app, so a feed of stored sentences would be permanently frozen in
/// whichever language each thing happened in. §6.1.7 says "derived from local facts on read", and
/// this is why — `BulletinCopy` renders at read time.
///
/// `.broadcast` is the deliberate exception and the only one: an operator wrote those words, in one
/// language, and there is nothing to re-derive them from.
///
/// ### What must never be in here
///
/// No coordinates, no ride titles, no names, no email addresses. The bulletin renders on a screen
/// someone may hand to a friend, and a ride title can be anything a user typed.
struct BulletinEntry: Equatable, Identifiable {
    let id: String
    let kind: BulletinKind
    let createdAtMillis: Int64
    /// Kind-specific facts. Numbers and ids only — see the note above about sentences and PII.
    var facts: [String: String] = [:]

    /// The feed is capped. A bulletin that grows forever becomes a log nobody scrolls, and the
    /// facts at the bottom are ones the user could not act on months ago either.
    static let maxRetained = 50

    // Fact keys, named once so the writer and the renderer cannot disagree about them.
    static let factTitle = "title"
    static let factBody = "body"
    static let factTag = "tag"
    static let factLink = "link"
    static let factRideCount = "ride_count"
    static let factDistanceMeters = "distance_meters"
    static let factStreakWeeks = "streak_weeks"
    static let factEndedAtMillis = "ended_at_millis"
    static let factLevelName = "level_name"
    static let factMilestoneCount = "milestone_count"
    static let factUnsyncedCount = "unsynced_count"
    static let factSinceMillis = "since_millis"
    static let factDaysAway = "days_away"

    func isUnread(lastSeenCreatedAtMillis: Int64?) -> Bool {
        guard let seen = lastSeenCreatedAtMillis else { return true }
        return createdAtMillis > seen
    }

    func fact(_ key: String) -> String? {
        guard let value = facts[key], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    func intFact(_ key: String) -> Int? { fact(key).flatMap(Int.init) }
    func int64Fact(_ key: String) -> Int64? { fact(key).flatMap(Int64.init) }
    func doubleFact(_ key: String) -> Double? { fact(key).flatMap(Double.init) }
}

/// What a bulletin entry is about.
///
/// Ordered roughly by how much the user would care if they saw only one — the answer to "which of
/// these earns the top of an empty list".
enum BulletinKind: String, CaseIterable {
    /// §6.3 operator broadcast. The only kind whose words are stored rather than derived.
    case broadcast = "BROADCAST"
    /// §6.1.1 #1 — a ride the app finished for you after a crash or force-quit.
    case rideSaved = "RIDE_SAVED"
    /// §6.1.5 #23 — cloud backup has been failing.
    case syncProblem = "SYNC_PROBLEM"
    /// §6.1.2 #8 — the weekly recap, kept after the notification is gone.
    case weeklyRecap = "WEEKLY_RECAP"
    /// §6.1.2 #9 — a level reached. Notifying would be redundant; the reveal already ran.
    case levelReached = "LEVEL_REACHED"
    /// §6.1.2 #9 — a milestone unlocked, same reasoning.
    case milestone = "MILESTONE"
    /// §6.1.5 #26 — a new version. Already an in-app prompt; never escalated to a notification.
    case versionNote = "VERSION_NOTE"

    /// §6.1.3 #13 — the return-after-absence notice.
    ///
    /// Present because §6.1.7's contract is "a copy of every notification actually sent". A Class C
    /// notice that interrupted someone and then cannot be found in the feed is the exact failure
    /// the bulletin exists to prevent — they saw it, swiped it, and it is gone.
    case returnNotice = "RETURN_NOTICE"
}

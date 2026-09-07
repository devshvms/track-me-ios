import Foundation

/// SCOPE_1.8.7 §6.1.7 — turning stored facts into the sentence a reader sees, at read time.
///
/// The iOS twin of `domain/bulletin/BulletinCopy.kt`, decision for decision.
///
/// This is the half that makes "derived from local facts on read" more than a phrase. An entry
/// stores counts and timestamps; the language and unit system are applied here, every time the feed
/// is drawn. Someone who switches TrackMe to German sees a German bulletin, including rows written
/// months ago in English.
enum BulletinCopy {

    /// Keys the *caller* fills in with locale-and-unit-formatted values just before rendering.
    /// They are never persisted — persisting them would put formatted text back in the store by the
    /// side door, which is the thing this design exists to avoid.
    static let formattedDistance = "formatted_distance"
    static let formattedEndedAt = "formatted_ended_at"
    static let formattedSince = "formatted_since"

    struct Row: Equatable {
        let title: String
        let body: String
        var link: String?
    }

    /// The strings a row needs, as a narrow protocol rather than the whole catalog — so the copy
    /// decisions are testable against a fake, and so it is obvious which strings this can reach.
    protocol Strings {
        var rideSavedTitle: String { get }
        var rideSavedBodyPlain: String { get }
        func rideSavedBody(endedAt: String, distance: String) -> String
        var weeklyRecapTitle: String { get }
        func weeklyRecapBody(rides: Int, distance: String) -> String
        func levelReachedTitle(level: String) -> String
        var levelReachedBody: String { get }
        func milestoneTitle(count: Int) -> String
        var milestoneBody: String { get }
        var syncProblemTitle: String { get }
        func syncProblemBody(unsynced: Int, since: String) -> String
        func versionNoteTitle(version: String) -> String
        var versionNoteBody: String { get }
    }

    /// The rendered row, or nil when the entry cannot be described.
    ///
    /// Nil rather than a placeholder: a row reading "—" is worse than one that is not there — it
    /// looks like the app knows something and will not say it — and an entry with missing facts is
    /// a bug we want to notice as an absence rather than paper over on screen.
    static func render(_ entry: BulletinEntry, strings: Strings) -> Row? {
        switch entry.kind {
        case .broadcast:
            // The one kind whose words are stored: a person wrote them, in one language.
            guard let title = entry.fact(BulletinEntry.factTitle),
                  let body = entry.fact(BulletinEntry.factBody) else { return nil }
            return Row(title: title, body: body, link: entry.fact(BulletinEntry.factLink))

        case .rideSaved:
            let endedAt = entry.fact(formattedEndedAt)
            let distance = entry.fact(formattedDistance)
            if let endedAt, let distance {
                return Row(title: strings.rideSavedTitle,
                           body: strings.rideSavedBody(endedAt: endedAt, distance: distance))
            }
            return Row(title: strings.rideSavedTitle, body: strings.rideSavedBodyPlain)

        case .weeklyRecap:
            guard let rides = entry.intFact(BulletinEntry.factRideCount),
                  let distance = entry.fact(formattedDistance) else { return nil }
            // A zero-ride week never reaches the feed either. §4.2 N2 is about notifications, but a
            // row reading "0 activities" is the same sentence with a quieter delivery.
            guard rides > 0 else { return nil }
            return Row(title: strings.weeklyRecapTitle,
                       body: strings.weeklyRecapBody(rides: rides, distance: distance))

        case .levelReached:
            guard let level = entry.fact(BulletinEntry.factLevelName) else { return nil }
            return Row(title: strings.levelReachedTitle(level: level), body: strings.levelReachedBody)

        case .milestone:
            guard let count = entry.intFact(BulletinEntry.factMilestoneCount) else { return nil }
            return Row(title: strings.milestoneTitle(count: count), body: strings.milestoneBody)

        case .syncProblem:
            guard let unsynced = entry.intFact(BulletinEntry.factUnsyncedCount),
                  let since = entry.fact(formattedSince) else { return nil }
            return Row(title: strings.syncProblemTitle,
                       body: strings.syncProblemBody(unsynced: unsynced, since: since))

        case .versionNote:
            guard let version = entry.fact(BulletinEntry.factTitle) else { return nil }
            return Row(title: strings.versionNoteTitle(version: version), body: strings.versionNoteBody)
        }
    }
}

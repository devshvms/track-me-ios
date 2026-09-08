import SwiftUI

/// SCOPE_1.8.7 §6.1.7 scenario 32 — the bulletin.
///
/// The surface that makes §6.0's one-per-week cap a trade rather than a loss. Everything the budget
/// refuses lands here: levels, milestones, recaps, sync problems, version notes, and a copy of every
/// notification actually sent.
///
/// Opening it marks it read; there is no per-row state. The feed is short and read at a glance, and
/// per-row read state would turn the badge into a to-do list — an obligation, which is the opposite
/// of what a surface designed to absorb an interruption budget should feel like.
struct BulletinView: View {
    @Bindable private var store = BulletinStore.shared
    @ObservedObject private var unitSettings = UnitSettings.shared

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    LocalizationHelper.localized("What's new"),
                    systemImage: "bell",
                    description: Text(LocalizationHelper.localized(
                        "Nothing to report. Anything TrackMe needs to tell you shows up here."
                    ))
                )
            } else {
                List {
                    ForEach(store.entries) { entry in
                        if let row = BulletinCopy.render(formatted(entry), strings: Copy()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).font(.subheadline.weight(.semibold))
                                Text(row.body).font(.footnote).foregroundColor(.secondary)
                                HStack {
                                    Text(Date(timeIntervalSince1970: Double(entry.createdAtMillis) / 1000),
                                         style: .date)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let link = row.link, let url = URL(string: link) {
                                        Spacer()
                                        // https-only was enforced by OperatorBroadcast.parse at the
                                        // boundary; nothing here can widen it.
                                        Link(LocalizationHelper.localized("Learn more"), destination: url)
                                            .font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section {
                        Button(LocalizationHelper.localized("Clear"), role: .destructive) {
                            store.clear()
                        }
                    }
                }
            }
        }
        .navigationTitle(LocalizationHelper.localized("What's new"))
        .navigationBarTitleDisplayMode(.inline)
        // Seen on open, not on scroll: a fact the user has had the chance to read is read.
        .task { store.markAllSeen() }
    }

    /// Applies the locale- and unit-dependent formatting at read time.
    ///
    /// The mechanism behind "derived from local facts on read": the store holds numbers, and these
    /// strings are produced fresh on every draw, so switching language or units re-renders the whole
    /// feed rather than leaving old rows frozen in the language they were written.
    private func formatted(_ entry: BulletinEntry) -> BulletinEntry {
        var copy = entry
        if let meters = entry.doubleFact(BulletinEntry.factDistanceMeters) {
            copy.facts[BulletinCopy.formattedDistance] =
                UnitFormatter.distance(meters: meters, unit: unitSettings.unit)
        }
        if let endedAt = entry.int64Fact(BulletinEntry.factEndedAtMillis) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            copy.facts[BulletinCopy.formattedEndedAt] =
                formatter.string(from: Date(timeIntervalSince1970: Double(endedAt) / 1000))
        }
        if let since = entry.int64Fact(BulletinEntry.factSinceMillis) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            copy.facts[BulletinCopy.formattedSince] =
                formatter.string(from: Date(timeIntervalSince1970: Double(since) / 1000))
        }
        return copy
    }
}

/// Adapts the app's localisation helper to the narrow protocol `BulletinCopy` asks for.
private struct Copy: BulletinCopy.Strings {
    var rideSavedTitle: String { LocalizationHelper.localized("Your ride was saved") }
    var rideSavedBodyPlain: String {
        LocalizationHelper.localized("The app closed while you were recording, so the ride was finished and kept.")
    }
    func rideSavedBody(endedAt: String, distance: String) -> String {
        LocalizationHelper.formatted(
            "Recording stopped at %1$@ because the app was closed. %2$@ was kept.", endedAt, distance
        )
    }
    var weeklyRecapTitle: String { LocalizationHelper.localized("Last week") }
    func weeklyRecapBody(rides: Int, distance: String) -> String {
        LocalizationHelper.formatted("%1$@ activities, %2$@.", String(rides), distance)
    }
    func levelReachedTitle(level: String) -> String {
        LocalizationHelper.formatted("You reached %@", level)
    }
    var levelReachedBody: String {
        LocalizationHelper.localized("From the active minutes you have recorded.")
    }
    func milestoneTitle(count: Int) -> String {
        LocalizationHelper.formatted("%@ activities recorded", String(count))
    }
    var milestoneBody: String { LocalizationHelper.localized("A milestone worth noting.") }
    var syncProblemTitle: String { LocalizationHelper.localized("Cloud backup is not working") }
    func syncProblemBody(unsynced: Int, since: String) -> String {
        LocalizationHelper.formatted(
            "%1$@ activities have not reached your backup since %2$@.", String(unsynced), since
        )
    }
    func versionNoteTitle(version: String) -> String {
        LocalizationHelper.formatted("TrackMe %@", version)
    }
    var versionNoteBody: String { LocalizationHelper.localized("A newer version is available.") }
    func syncProblemBodyNoDate(unsynced: Int) -> String {
        LocalizationHelper.formatted("%@ activities have not reached your cloud backup.", String(unsynced))
    }
    var returnNoticeTitle: String { LocalizationHelper.localized("Your rides are still here") }
    func returnNoticeBody(days: Int) -> String {
        LocalizationHelper.formatted(
            "Your last recorded activity was %@ days ago. Everything you recorded is still on your phone.",
            String(days)
        )
    }
}

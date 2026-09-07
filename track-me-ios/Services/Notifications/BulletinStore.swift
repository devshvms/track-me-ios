import Foundation
import Observation

/// SCOPE_1.8.7 §6.1.7 — the bulletin's storage.
///
/// The iOS twin of `data/local/BulletinStore.kt`. Append-only from the caller's point of view,
/// capped, newest first, and with no network dependency of any kind: everything in here was
/// computed on this device or arrived through a channel that already landed.
///
/// `UserDefaults` rather than SwiftData, matching Android's choice of preferences over Room: fifty
/// short rows, written from background delivery with no model container open, and a schema entry is
/// a liability the app carries forever — TASK-309 was three releases of work to remove two of them.
@Observable
@MainActor
final class BulletinStore {
    static let shared = BulletinStore()

    private let defaults: UserDefaults
    private let entriesKey = "trackme_bulletin_entries"
    private let lastSeenKey = "trackme_bulletin_last_seen"

    private(set) var entries: [BulletinEntry] = []
    private(set) var lastSeenCreatedAtMillis: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.decode(defaults.string(forKey: entriesKey))
        self.lastSeenCreatedAtMillis = (defaults.object(forKey: lastSeenKey) as? NSNumber)?.int64Value
    }

    /// Adds an entry, ignoring one whose id is already present.
    ///
    /// Idempotent by id because the same fact reaches here by more than one route — a broadcast by
    /// push *and* by the foreground reconcile, a recap notified *and* read in-app. A duplicated row
    /// would make the unread badge lie, and the badge is the only thing that makes an un-notified
    /// fact discoverable at all.
    @discardableResult
    func add(_ entry: BulletinEntry) -> Bool {
        guard !entries.contains(where: { $0.id == entry.id }) else { return false }
        entries = (entries + [entry])
            .sorted { $0.createdAtMillis > $1.createdAtMillis }
            .prefix(BulletinEntry.maxRetained)
            .map { $0 }
        persist()
        return true
    }

    /// Everything the user has not seen yet. The badge counts these.
    func unread() -> [BulletinEntry] {
        entries.filter { $0.isUnread(lastSeenCreatedAtMillis: lastSeenCreatedAtMillis) }
    }

    /// Marks everything currently in the feed as seen. Never moves backwards.
    ///
    /// Called when the bulletin is opened rather than per-row: the feed is short and read at a
    /// glance, and per-row read state would make the badge a to-do list — the shape that turns a
    /// calm surface into an obligation.
    func markAllSeen() {
        guard let newest = entries.map(\.createdAtMillis).max() else { return }
        if let current = lastSeenCreatedAtMillis, newest <= current { return }
        lastSeenCreatedAtMillis = newest
        defaults.set(NSNumber(value: newest), forKey: lastSeenKey)
    }

    /// §6.1.7: "capped, clearable". Nothing here is a record we need to keep.
    func clear() {
        entries = []
        lastSeenCreatedAtMillis = nil
        defaults.removeObject(forKey: entriesKey)
        defaults.removeObject(forKey: lastSeenKey)
    }

    private func persist() {
        let rows: [[String: Any]] = entries.map { entry in
            [
                "id": entry.id,
                "kind": entry.kind.rawValue,
                "created_at_millis": NSNumber(value: entry.createdAtMillis),
                "facts": entry.facts,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: entriesKey)
    }

    /// Re-validated on read, not trusted because we wrote it. A downgrade after a future release
    /// added a kind, a restore from another build, or a tampered defaults file all land here — and
    /// a row this build cannot describe would be a blank line in the feed.
    private static func decode(_ json: String?) -> [BulletinEntry] {
        guard let json, let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let rawKind = row["kind"] as? String,
                  let kind = BulletinKind(rawValue: rawKind) else { return nil }
            return BulletinEntry(
                id: id,
                kind: kind,
                createdAtMillis: (row["created_at_millis"] as? NSNumber)?.int64Value ?? 0,
                facts: (row["facts"] as? [String: String]) ?? [:]
            )
        }
    }
}

/// SCOPE_1.8.7 §6.1.7 — the adapters that turn facts into bulletin rows.
///
/// "A copy of every notification actually sent" is what these implement, and the reason they live
/// together rather than scattered through the notifiers: the bulletin is only trustworthy if it is
/// **complete**. A fact that interrupted someone and then is not in the feed is worse than one that
/// never interrupted — they saw it, swiped it, and now cannot find it.
///
/// Every id is derived from the fact itself rather than from a clock, so the same fact arriving by
/// two routes produces one row.
enum BulletinAdapters {

    static func from(_ broadcast: OperatorBroadcast) -> BulletinEntry {
        var facts: [String: String] = [
            BulletinEntry.factTitle: broadcast.title,
            BulletinEntry.factBody: broadcast.body,
            BulletinEntry.factTag: broadcast.tag.rawValue,
        ]
        if let link = broadcast.learnMoreUrl { facts[BulletinEntry.factLink] = link }
        return BulletinEntry(
            id: "broadcast:\(broadcast.id)",
            kind: .broadcast,
            createdAtMillis: broadcast.createdAtMillis,
            facts: facts
        )
    }

    static func from(_ recap: WeeklyRecap) -> BulletinEntry {
        BulletinEntry(
            // Keyed by week, so a recap both notified and read in-app is one row.
            id: "recap:\(recap.weekStartEpochDay)",
            kind: .weeklyRecap,
            // The week it describes, not the moment it was noticed — otherwise a recap read late
            // sorts above facts that actually happened after it.
            createdAtMillis: Int64(recap.weekStartEpochDay) * 86_400_000,
            facts: [
                BulletinEntry.factRideCount: String(recap.rideCount),
                BulletinEntry.factDistanceMeters: String(recap.distanceMeters),
                BulletinEntry.factStreakWeeks: String(recap.streakWeeks),
            ]
        )
    }

    /// One row per recovered ride, keyed by end time.
    ///
    /// Per ride rather than per recovery *event*: the notification says "3 rides were saved" because
    /// it has one line, but the feed has room to say which three, and a user checking whether a
    /// particular ride survived is the whole reason to look.
    static func from(_ summary: RecoverySummary) -> [BulletinEntry] {
        summary.recovered.map { ride in
            let endedAt = Int64(ride.endTime.timeIntervalSince1970 * 1000)
            return BulletinEntry(
                id: "ride-saved:\(endedAt)",
                kind: .rideSaved,
                createdAtMillis: endedAt,
                facts: [
                    BulletinEntry.factEndedAtMillis: String(endedAt),
                    BulletinEntry.factDistanceMeters: String(ride.distanceMeters),
                ]
            )
        }
    }
}

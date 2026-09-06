import Foundation
import Observation

/// SCOPE_1.8.7 §6.3 — the durable half of an operator broadcast.
///
/// A notification is something you swipe away at a traffic light. If the banner were the only place
/// a broadcast existed, "we told everyone" would mean "we told everyone who happened to be
/// looking" — not a claim worth making about a message saying the build someone is running has a
/// defect.
///
/// So every broadcast lands here as well, whichever route it arrived by, and the in-app surface
/// reads from here. This is also the seed of §6.1.7's bulletin: the same store with more kinds of
/// fact in it is the whole feature.
///
/// `UserDefaults` rather than SwiftData, matching Android's choice of preferences over Room: the
/// corpus is a handful of short rows, aggressively pruned, and it has to be writable from a
/// background push delivery with no model container open. A schema migration for this would cost
/// more than it could ever buy — and TASK-309 is a recent reminder of what a schema entry costs
/// once it exists.
@Observable
@MainActor
final class BroadcastStore {
    static let shared = BroadcastStore()

    /// Operational messages go stale. Twenty is far more than an honest operator will ever have
    /// outstanding, and an unbounded list turns a preferences file into a log.
    static let maxRetained = 20

    private let defaults: UserDefaults
    private let broadcastsKey = "trackme_broadcasts"
    private let lastSeenKey = "trackme_broadcasts_last_seen"

    private(set) var broadcasts: [OperatorBroadcast] = []
    private(set) var lastSeenCreatedAtMillis: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.broadcasts = Self.decode(defaults.string(forKey: broadcastsKey))
        self.lastSeenCreatedAtMillis = defaults.object(forKey: lastSeenKey) as? Int64
            ?? (defaults.object(forKey: lastSeenKey) as? NSNumber)?.int64Value
    }

    /// Stores a broadcast, ignoring any later copy with the same id.
    ///
    /// Idempotent by id because the same broadcast genuinely arrives twice: once by push, once by
    /// the foreground read of the `broadcasts` collection. Two copies would show the user the same
    /// problem twice and make the unread count lie.
    ///
    /// - Returns: true when this was new. The caller uses it to decide whether to post a
    ///   notification, so a duplicate arrival never re-interrupts.
    @discardableResult
    func store(_ broadcast: OperatorBroadcast) -> Bool {
        guard !broadcasts.contains(where: { $0.id == broadcast.id }) else { return false }
        broadcasts = (broadcasts + [broadcast])
            .sorted { $0.createdAtMillis > $1.createdAtMillis }
            .prefix(Self.maxRetained)
            .map { $0 }
        persist()
        return true
    }

    /// Marks everything up to `createdAtMillis` as seen. Never moves backwards.
    func markSeen(createdAtMillis: Int64) {
        if let current = lastSeenCreatedAtMillis, createdAtMillis <= current { return }
        lastSeenCreatedAtMillis = createdAtMillis
        defaults.set(NSNumber(value: createdAtMillis), forKey: lastSeenKey)
    }

    /// Broadcasts that are both unread and true for this build.
    func unread(versionCode: Int) -> [OperatorBroadcast] {
        broadcasts.filter {
            $0.isUnread(lastSeenCreatedAtMillis: lastSeenCreatedAtMillis)
                && $0.applies(toVersionCode: versionCode)
        }
    }

    private func persist() {
        let rows: [[String: Any]] = broadcasts.map { broadcast in
            var row: [String: Any] = [
                "id": broadcast.id,
                "tag": broadcast.tag.rawValue,
                "title": broadcast.title,
                "body": broadcast.body,
                "created_at_millis": NSNumber(value: broadcast.createdAtMillis),
            ]
            if let ceiling = broadcast.appliesToVersionsAtOrBelow {
                row["applies_to_versions_at_or_below"] = NSNumber(value: ceiling)
            }
            if let link = broadcast.learnMoreUrl { row["learn_more_url"] = link }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: broadcastsKey)
    }

    /// Re-validated on read, not trusted because we wrote it. A downgrade, a restore from another
    /// build, or a tampered defaults file all land here, and the parser is the only thing between
    /// them and a notification.
    private static func decode(_ json: String?) -> [OperatorBroadcast] {
        guard let json, let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { OperatorBroadcast.parse($0) }
    }
}

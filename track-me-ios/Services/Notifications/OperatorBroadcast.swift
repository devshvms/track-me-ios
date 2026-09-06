import Foundation

/// SCOPE_1.8.7 §6.3 — a Class D operator broadcast, and the rules for believing one.
///
/// The iOS twin of `domain/notifications/OperatorBroadcast.kt`, proved against the same frozen
/// `operator-broadcast-v1.json`.
///
/// This is the only content in the app that arrives from the network and becomes a notification.
/// Everything else TrackMe says, it computed from local facts. So the parser is strict and silent:
/// a malformed broadcast is dropped, never repaired, never partially rendered.
///
/// ### The closed tag vocabulary is the promotional ban
///
/// §6.3 says "nothing promotional, ever", and that is enforced in three places, none of which is a
/// document: the admin UI offers only these three tags, the endpoint rejects anything else, and
/// `parse` refuses it here. A rule that lives only in prose loses to a good idea on a slow month —
/// and losing that argument once makes "notification permission" stop being a sufficient basis for
/// delivering any of this.
struct OperatorBroadcast: Equatable {
    let id: String
    let tag: BroadcastTag
    let title: String
    let body: String
    let createdAtMillis: Int64
    /// Only meaningful for `.update`: the newest build the message is *true* for.
    ///
    /// The single filter in the design, and it is about correctness rather than targeting. Telling
    /// someone already running the fixed build to update is noise, and noise on this channel is how
    /// people learn to swipe away the one message that mattered. The client decides, not the
    /// server, so the filter has exactly one axis and cannot quietly become segmentation.
    var appliesToVersionsAtOrBelow: Int?
    var learnMoreUrl: String?

    /// Longer than the notification banner shows is a title whose end nobody reads.
    static let maxTitleLength = 80

    /// Long enough for "what is wrong, what to do, when it will be fixed".
    static let maxBodyLength = 480

    /// Whether this message is true for a build running `versionCode`. Inclusive at the boundary.
    func applies(toVersionCode versionCode: Int) -> Bool {
        guard let ceiling = appliesToVersionsAtOrBelow else { return true }
        return versionCode <= ceiling
    }

    func isUnread(lastSeenCreatedAtMillis: Int64?) -> Bool {
        guard let seen = lastSeenCreatedAtMillis else { return true }
        return createdAtMillis > seen
    }

    /// Parses from an untrusted dictionary — an FCM data payload or a Firestore document.
    ///
    /// Returns nil for anything that does not satisfy the contract. Refusing is always safe: the
    /// same broadcast is readable from Firestore on next foreground, so a dropped push costs a
    /// delay, while a rendered malformed one costs the channel its credibility.
    static func parse(_ raw: [AnyHashable: Any]) -> OperatorBroadcast? {
        guard let id = string(raw, "id"), !id.isEmpty,
              let tag = BroadcastTag(rawValue: string(raw, "tag") ?? "") else { return nil }

        guard let title = string(raw, "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= maxTitleLength else { return nil }

        guard let body = string(raw, "body")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty, body.count <= maxBodyLength else { return nil }

        guard let createdAt = int64(raw, "created_at_millis") else { return nil }

        let ceiling = int(raw, "applies_to_versions_at_or_below")
        // Version filtering has an operational meaning only for an update notice. Anywhere else it
        // is a segmentation lever with no honest use, so the shape forbids it rather than relying
        // on nobody reaching for it.
        if ceiling != nil && tag != .update { return nil }

        var learnMore = string(raw, "learn_more_url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = learnMore, candidate.isEmpty { learnMore = nil }
        if let candidate = learnMore, !candidate.hasPrefix("https://") { return nil }

        return OperatorBroadcast(
            id: id,
            tag: tag,
            title: title,
            body: body,
            createdAtMillis: createdAt,
            appliesToVersionsAtOrBelow: ceiling,
            learnMoreUrl: learnMore
        )
    }

    private static func string(_ raw: [AnyHashable: Any], _ key: String) -> String? {
        raw[key] as? String
    }

    /// FCM data payloads are all strings; Firestore hands back numbers. Both must work, or a push
    /// and the foreground read of the same row would disagree about what the user was told.
    private static func int64(_ raw: [AnyHashable: Any], _ key: String) -> Int64? {
        if let number = raw[key] as? NSNumber { return number.int64Value }
        if let text = raw[key] as? String { return Int64(text) }
        return nil
    }

    private static func int(_ raw: [AnyHashable: Any], _ key: String) -> Int? {
        if let number = raw[key] as? NSNumber { return number.intValue }
        if let text = raw[key] as? String { return Int(text) }
        return nil
    }
}

/// The three things an operator may say. There is no fourth, and adding one is meant to be
/// inconvenient — see `OperatorBroadcast`.
///
/// Raw values are matched exactly. Case-insensitive parsing would accept "urgent" from a payload
/// that never came from our admin page, and being lenient about the one field that gates the whole
/// vocabulary defeats the point of having one.
enum BroadcastTag: String, CaseIterable {
    /// A newer version fixes something the user is living with.
    case update = "UPDATE"
    /// A service the app depends on is degraded or down.
    case maintenance = "MAINTENANCE"
    /// A defect in the running build that the user needs to know about now.
    case urgent = "URGENT"
}

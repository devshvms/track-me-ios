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
    /// Only meaningful for `.update`: the newest **release** the message is true for, as a dotted
    /// marketing version ("1.8.7").
    ///
    /// The single filter in the design, and it is about correctness rather than targeting. Telling
    /// someone already running the fixed build to update is noise, and noise on this channel is how
    /// people learn to swipe away the one message that mattered.
    ///
    /// A *release* rather than a build number: `CFBundleVersion` is 7 here and Android's
    /// `versionCode` is 29 for the same release, so the integer this replaced could not mean one
    /// thing across platforms — the same broadcast selected two different populations.
    var appliesToReleasesAtOrBelow: String?
    var learnMoreUrl: String?

    /// Longer than the notification banner shows is a title whose end nobody reads.
    static let maxTitleLength = 80

    /// Long enough for "what is wrong, what to do, when it will be fixed".
    static let maxBodyLength = 480

    /// Whether this message is true for a device running `release`. Inclusive at the boundary.
    ///
    /// - Parameter release: the app's marketing version, i.e. `CFBundleShortVersionString`.
    func applies(toRelease release: String) -> Bool {
        guard let ceiling = appliesToReleasesAtOrBelow else { return true }
        return ReleaseVersion.compare(release, ceiling) <= 0
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

        // v1's integer key is refused outright rather than accepted alongside the new one. It meant
        // a different build on each platform, so a stale sender using it would silently target
        // nobody — and a parser that quietly ignores a retired field never finds out.
        if raw["applies_to_versions_at_or_below"] != nil { return nil }

        var ceiling = string(raw, "applies_to_releases_at_or_below")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = ceiling, candidate.isEmpty { return nil }
        if raw["applies_to_releases_at_or_below"] != nil && ceiling == nil { return nil }
        if let candidate = ceiling, !ReleaseVersion.isValid(candidate) { return nil }
        if ceiling != nil && tag != .update { ceiling = nil; return nil }

        var learnMore = string(raw, "learn_more_url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = learnMore, candidate.isEmpty { learnMore = nil }
        if let candidate = learnMore, !candidate.hasPrefix("https://") { return nil }

        return OperatorBroadcast(
            id: id,
            tag: tag,
            title: title,
            body: body,
            createdAtMillis: createdAt,
            appliesToReleasesAtOrBelow: ceiling,
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

/// Dotted release strings, compared the way a person means them.
///
/// Component-wise and **numeric**, not lexicographic. String comparison puts `"1.9.9"` above
/// `"1.10.0"`, which would silently exclude every device that most needs an update notice — and the
/// failure looks like the broadcast simply reaching nobody, which is the hardest kind to notice.
///
/// Missing components are zero, so `"1.8"` and `"1.8.0"` are the same release. Byte-for-byte with
/// Android's `ReleaseVersion`.
enum ReleaseVersion {

    static let maxLength = 64
    static let maxComponent = Int32.max

    /// Dotted digits and nothing else. A ceiling the platforms might parse differently is worse
    /// than no ceiling.
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxLength,
              value.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else {
            return false
        }
        return value.split(separator: ".").allSatisfy {
            guard let component = Int64($0) else { return false }
            return component <= Int64(maxComponent)
        }
    }

    /// -1, 0 or 1. Returns 0 for anything unparseable, so a malformed pair never excludes anyone.
    static func compare(_ left: String, _ right: String) -> Int {
        guard isValid(left), isValid(right) else { return 0 }
        let a = left.split(separator: ".").map { Int($0)! }
        let b = right.split(separator: ".").map { Int($0)! }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

import CryptoKit
import Foundation

enum GroupSessionStatus: String, Codable {
    case idle = "IDLE"
    case preparing = "PREPARING"
    case live = "LIVE"
    case degraded = "DEGRADED"
    case ended = "ENDED"
}

enum GroupEndReason: String, Codable {
    case ended
    case expired
    case removed
}

struct GroupEndNotice: Equatable, Codable {
    let reason: GroupEndReason
    let rideStillRecording: Bool
}

struct GroupSessionState: Equatable, Codable {
    var status: GroupSessionStatus = .idle
    var groupId: String?
    var joinCode: String?
    var inviteToken: String?
    var groupName: String?
    var destinationLat: Double?
    var destinationLng: Double?
    var startAtMillis: Int64?
    var isLeader = false
    var hasStarted = false
    var expiresAtMillis: Int64 = 0
    var maxMembers = 0
    var rev = 0
    var syncIntervalSec = GroupBackoff.defaultSyncIntervalSec
    var positions: [GroupWire.MemberPosition] = []
    var statuses: [GroupWire.MemberStatus] = []
    var roster: [GroupWire.RosterEntry] = []
    var degradedSince: Date?
    var consecutiveFailures = 0
    var joinedAtMillis: Int64 = 0
    var joinedAtElapsedMillis: Int64 = 0
    var isSharingPosition = false
    var lastSuccessfulSyncElapsedMillis: Int64?
    var lastOwnPositionAckElapsedMillis: Int64?
    var lastStatusAckElapsedMillis: Int64?
    var lastSyncFailureKind: GroupSyncFailureKind?
    var selfStatus: RiderStatus?
    var selfStatusAgeAnchor: StatusAge.Anchor?
    var isSelfStatusAcknowledged = false
    var isClearingStatus = false
    var isStatusUndoAvailable = false
    var alertsMuted = false
    var isActive: Bool {
        status == .preparing || status == .live || status == .degraded
    }

    var memberCount: Int {
        max(roster.count, positions.count + 1)
    }
}
extension GroupSessionState {
    /// TASK-289 — the leader is the only member of their own group.
    ///
    /// Lives here rather than inside `CommunityView` so it can be tested: it decides whether a
    /// user is shown the one action that makes their group useful, and getting it wrong in either
    /// direction is expensive. It is the exact counterpart of Android's
    /// `CommunityUiState.aloneInGroup`, leader condition included — a member who joined by code and
    /// happens to be looking at a roster of one must not be told to invite people to somebody
    /// else's group.
    var isAloneInGroup: Bool { isLeader && roster.count < 2 }
}


enum GroupWire {
    enum StatusRequestOperation: Equatable {
        case set(envelope: String)
        case clear
    }

    struct MemberPosition: Equatable, Codable, Identifiable {
        var id: String { uid }
        let uid: String
        let lat: Double
        let lng: Double
        let speedMps: Double?
        let headingDeg: Double?
        let batteryPercent: Int?
        let moving: Bool
        let riding: Bool
        let serverTsMillis: Int64
        let ageAnchor: StatusAge.Anchor?
    }

    struct MemberStatus: Equatable, Codable, Identifiable {
        var id: String { uid }
        let uid: String
        let status: RiderStatus
        let serverTsMillis: Int64
        let ageAnchor: StatusAge.Anchor
    }

    struct SlotAck: Equatable {
        let envelope: String
        let serverTsMillis: Int64
    }

    struct RosterEntry: Equatable, Codable, Identifiable {
        var id: String { uid }
        let uid: String
        let displayName: String?
        let initials: String?
        let photoUrl: String?
    }

    struct GroupMeta: Equatable, Codable {
        let name: String?
        let ownerDisplayName: String?
        let destLat: Double?
        let destLng: Double?
        let startAtMillis: Int64?

        var hasDestination: Bool { destLat != nil && destLng != nil }
    }

    struct CreateResult: Equatable {
        let groupId: String
        let joinCode: String
        let state: String
        let expiresAtMillis: Int64
        let maxMembers: Int
        let syncIntervalSec: Int
        let rev: Int
    }

    struct JoinResult: Equatable {
        let groupId: String
        let state: String
        let expiresAtMillis: Int64
        let maxMembers: Int
        let syncIntervalSec: Int
        let memberCount: Int
        let rev: Int
        let rejoined: Bool
        let meta: GroupMeta?
    }

    struct StateResult: Equatable {
        let state: String
        let expiresAtMillis: Int64?
        let rev: Int?
        let metaUpdated: Bool
        let meta: GroupMeta?
    }

    struct ResolveResult: Equatable {
        let groupId: String
        let state: String
        let memberCount: Int
        let maxMembers: Int
        let expiresAtMillis: Int64
        let wrappedToken: String?
        let encryptedMeta: String?
        let joinCode: String?
    }

    struct SyncResult: Equatable {
        let state: String
        let expiresAtMillis: Int64
        let rev: Int
        let maxMembers: Int
        let nextSyncInSec: Int
        let serverNowMillis: Int64?
        let positions: [MemberPosition]
        let selfPositionAck: SlotAck?
        let statuses: [MemberStatus]
        let selfStatus: MemberStatus?
        let selfStatusAck: SlotAck?
        let statusesFieldPresent: Bool
        let roster: [RosterEntry]?
        let meta: GroupMeta?
        let undecryptable: [String]
        let unreadableStatusUIDs: Set<String>
    }

    enum Error: Swift.Error, Equatable {
        case malformedResponse
        case missingField(String)
    }

    static func parseCreate(_ body: Data) throws -> CreateResult {
        let json = try object(body)
        return CreateResult(
            groupId: try string(json, "groupId"),
            joinCode: try string(json, "joinCode"),
            state: json["state"] as? String ?? "PREPARING",
            expiresAtMillis: try millis(json, "expiresAt"),
            maxMembers: json["maxMembers"] as? Int ?? 5,
            syncIntervalSec: json["syncIntervalSec"] as? Int ?? GroupBackoff.defaultSyncIntervalSec,
            rev: json["rev"] as? Int ?? 1
        )
    }

    static func parseResolve(_ body: Data) throws -> ResolveResult {
        let json = try object(body)
        return ResolveResult(
            groupId: try string(json, "groupId"),
            state: json["state"] as? String ?? "PREPARING",
            memberCount: json["memberCount"] as? Int ?? 0,
            maxMembers: json["maxMembers"] as? Int ?? 5,
            expiresAtMillis: try millis(json, "expiresAt"),
            wrappedToken: nonEmpty(json["wrappedToken"] as? String),
            encryptedMeta: nonEmpty(json["meta"] as? String),
            joinCode: nonEmpty(json["joinCode"] as? String)
        )
    }

    static func parseJoin(_ body: Data, key: SymmetricKey) throws -> JoinResult {
        let json = try object(body)
        return JoinResult(
            groupId: try string(json, "groupId"),
            state: json["state"] as? String ?? "PREPARING",
            expiresAtMillis: try millis(json, "expiresAt"),
            maxMembers: json["maxMembers"] as? Int ?? 5,
            syncIntervalSec: json["syncIntervalSec"] as? Int ?? GroupBackoff.defaultSyncIntervalSec,
            memberCount: json["memberCount"] as? Int ?? 1,
            rev: json["rev"] as? Int ?? 0,
            rejoined: json["rejoined"] as? Bool ?? false,
            meta: nonEmpty(json["meta"] as? String).flatMap { try? openMeta(key: key, envelope: $0) }
        )
    }

    static func parseState(_ body: Data, key: SymmetricKey) throws -> StateResult {
        let json = try object(body)
        return StateResult(
            state: json["state"] as? String ?? "LIVE",
            expiresAtMillis: int64(json["expiresAt"]),
            rev: json["rev"] as? Int,
            metaUpdated: json["metaUpdated"] as? Bool ?? false,
            meta: nonEmpty(json["meta"] as? String).flatMap { try? openMeta(key: key, envelope: $0) }
        )
    }

    static func parseSync(
        _ body: Data,
        key: SymmetricKey,
        selfUid: String,
        legacyWallNowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> SyncResult {
        let json = try object(body)
        let receivedAtElapsedMillis = StatusAge.elapsedMillis()
        let reportedServerNow = int64(json["serverNow"]) ?? int64(json["serverNowMs"])
        // `serverNow` is the 1.7.2 wire name. The draft `serverNowMs` fallback is harmless for
        // mixed preview builds; a missing/zero value means an older relay, where §4b requires the
        // previous wall-clock behaviour rather than hiding every age.
        let serverNowMillis = reportedServerNow.flatMap { $0 > 0 ? $0 : nil } ?? legacyWallNowMillis
        var positions: [MemberPosition] = []
        var selfPositionAck: SlotAck?
        var undecryptable: [String] = []

        if let pos = json["positions"] as? [String: Any] {
            for (uid, rawEntry) in pos {
                guard let entry = rawEntry as? [String: Any],
                      let envelope = nonEmpty(entry["e"] as? String) else { continue }
                let ts = int64(entry["ts"]) ?? 0
                if uid == selfUid {
                    selfPositionAck = SlotAck(envelope: envelope, serverTsMillis: ts)
                    continue
                }
                do {
                    let plain = try GroupCrypto.open(key: key, envelope: envelope, purpose: .position(uid: uid))
                    let decoded = try object(Data(plain.utf8))
                    let anchor = StatusAge.anchorPosition(
                        serverNowMillis: serverNowMillis,
                        serverTimestampMillis: ts,
                        receivedAtElapsedMillis: receivedAtElapsedMillis
                    )
                    positions.append(MemberPosition(
                        uid: uid,
                        lat: try double(decoded, "lat"),
                        lng: try double(decoded, "lng"),
                        speedMps: optionalDouble(decoded["spd"]),
                        headingDeg: optionalDouble(decoded["hdg"]),
                        batteryPercent: decoded["bat"] as? Int,
                        moving: decoded["moving"] as? Bool ?? false,
                        riding: decoded["riding"] as? Bool ?? false,
                        serverTsMillis: ts,
                        ageAnchor: anchor
                    ))
                } catch {
                    undecryptable.append(uid)
                }
            }
        }

        let statusesFieldPresent = json["statuses"] is [String: Any]
        var statuses: [MemberStatus] = []
        var selfStatus: MemberStatus?
        var selfStatusAck: SlotAck?
        var unreadableStatusUIDs: Set<String> = []
        if let rawStatuses = json["statuses"] as? [String: Any] {
            for (uid, rawEntry) in rawStatuses {
                guard let entry = rawEntry as? [String: Any],
                      let envelope = nonEmpty(entry["e"] as? String) else {
                    unreadableStatusUIDs.insert(uid)
                    continue
                }
                guard let ts = int64(entry["ts"]), ts > 0 else {
                    unreadableStatusUIDs.insert(uid)
                    continue
                }
                do {
                    let plain = try GroupCrypto.open(key: key, envelope: envelope, purpose: .status(uid: uid))
                    let decoded = try object(Data(plain.utf8))
                    guard let status = RiderStatusCodec.parse(nonEmpty(decoded["st"] as? String)) else {
                        unreadableStatusUIDs.insert(uid)
                        continue
                    }
                    let ageAnchor = StatusAge.anchorStatus(
                        serverNowMillis: serverNowMillis,
                        serverTimestampMillis: ts,
                        statusAgeSeconds: int64(decoded["stAge"]),
                        receivedAtElapsedMillis: receivedAtElapsedMillis
                    )
                    let memberStatus = MemberStatus(
                        uid: uid,
                        status: status,
                        serverTsMillis: ts,
                        ageAnchor: ageAnchor
                    )
                    if uid == selfUid {
                        selfStatus = memberStatus
                        selfStatusAck = SlotAck(envelope: envelope, serverTsMillis: ts)
                    } else {
                        statuses.append(memberStatus)
                    }
                } catch {
                    unreadableStatusUIDs.insert(uid)
                    undecryptable.append(uid)
                }
            }
        }

        let roster: [RosterEntry]?
        if let rosterJson = json["roster"] as? [String: Any] {
            var entries: [RosterEntry] = []
            for (uid, rawEnvelope) in rosterJson {
                guard let envelope = nonEmpty(rawEnvelope as? String) else { continue }
                do {
                    let plain = try GroupCrypto.open(key: key, envelope: envelope, purpose: .roster(uid: uid))
                    let decoded = try object(Data(plain.utf8))
                    entries.append(RosterEntry(
                        uid: uid,
                        displayName: nonEmpty(decoded["displayName"] as? String),
                        initials: nonEmpty(decoded["initials"] as? String),
                        photoUrl: nonEmpty(decoded["photoUrl"] as? String)
                    ))
                } catch {
                    undecryptable.append(uid)
                }
            }
            roster = entries
        } else {
            roster = nil
        }

        let meta = nonEmpty(json["meta"] as? String).flatMap { try? openMeta(key: key, envelope: $0) }
        return SyncResult(
            state: json["state"] as? String ?? "LIVE",
            expiresAtMillis: int64(json["expiresAt"]) ?? 0,
            rev: json["rev"] as? Int ?? 0,
            maxMembers: json["maxMembers"] as? Int ?? 5,
            nextSyncInSec: json["nextSyncInSec"] as? Int ?? GroupBackoff.defaultSyncIntervalSec,
            serverNowMillis: serverNowMillis,
            positions: positions,
            selfPositionAck: selfPositionAck,
            statuses: statuses,
            selfStatus: selfStatus,
            selfStatusAck: selfStatusAck,
            statusesFieldPresent: statusesFieldPresent,
            roster: roster,
            meta: meta,
            undecryptable: undecryptable,
            unreadableStatusUIDs: unreadableStatusUIDs
        )
    }

    static func statusRequestFields(for operation: StatusRequestOperation) -> [String: Any] {
        switch operation {
        case .set(let envelope):
            ["statusOp": "set", "status": envelope]
        case .clear:
            ["statusOp": "clear"]
        }
    }

    static func encodePosition(
        lat: Double,
        lng: Double,
        speedMps: Double?,
        headingDeg: Double?,
        batteryPercent: Int?,
        moving: Bool,
        riding: Bool
    ) throws -> String {
        var payload: [String: Any] = ["lat": lat, "lng": lng, "moving": moving, "riding": riding]
        if let speedMps { payload["spd"] = speedMps }
        if let headingDeg { payload["hdg"] = headingDeg }
        if let batteryPercent { payload["bat"] = batteryPercent }
        return try jsonString(payload)
    }

    static func encodeStatus(_ status: RiderStatus, statusAgeSeconds: Int64?) throws -> String {
        var payload: [String: Any] = ["st": status.raw]
        if let statusAgeSeconds { payload["stAge"] = max(0, statusAgeSeconds) }
        return try jsonString(payload)
    }

    static func encodeRoster(displayName: String?, initials: String?, photoUrl: String?) throws -> String {
        var payload: [String: Any] = [:]
        if let displayName = nonEmpty(displayName) { payload["displayName"] = displayName }
        if let initials = nonEmpty(initials) { payload["initials"] = initials }
        if let photoUrl = nonEmpty(photoUrl) { payload["photoUrl"] = photoUrl }
        return try jsonString(payload)
    }

    static func encodeMeta(
        name: String,
        ownerDisplayName: String?,
        destLat: Double? = nil,
        destLng: Double? = nil,
        startAtMillis: Int64? = nil
    ) throws -> String {
        var payload: [String: Any] = ["name": name]
        if let ownerDisplayName = nonEmpty(ownerDisplayName) { payload["ownerDisplayName"] = ownerDisplayName }
        if let destLat, let destLng {
            payload["destLat"] = destLat
            payload["destLng"] = destLng
        }
        if let startAtMillis, startAtMillis > 0 { payload["startAt"] = startAtMillis }
        return try jsonString(payload)
    }

    static func errorCode(_ body: Data?) -> String? {
        guard let body, let json = try? object(body) else { return nil }
        return nonEmpty(json["code"] as? String)
    }

    static func initials(for displayName: String?) -> String? {
        guard let displayName = nonEmpty(displayName) else { return nil }
        let words = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let first = words.first?.first else { return nil }
        guard let last = words.dropFirst().last?.first else { return String(first).uppercased() }
        return "\(first)\(last)".uppercased()
    }

    private static func openMeta(key: SymmetricKey, envelope: String) throws -> GroupMeta {
        let plain = try GroupCrypto.open(key: key, envelope: envelope, purpose: .meta)
        let json = try object(Data(plain.utf8))
        return GroupMeta(
            name: nonEmpty(json["name"] as? String),
            ownerDisplayName: nonEmpty(json["ownerDisplayName"] as? String),
            destLat: optionalDouble(json["destLat"]),
            destLng: optionalDouble(json["destLng"]),
            startAtMillis: int64(json["startAt"])
        )
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformedResponse
        }
        return json
    }

    private static func jsonString(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ json: [String: Any], _ field: String) throws -> String {
        guard let value = nonEmpty(json[field] as? String) else { throw Error.missingField(field) }
        return value
    }

    private static func double(_ json: [String: Any], _ field: String) throws -> Double {
        guard let value = optionalDouble(json[field]) else { throw Error.missingField(field) }
        return value
    }

    private static func millis(_ json: [String: Any], _ field: String) throws -> Int64 {
        guard let value = int64(json[field]) else { throw Error.missingField(field) }
        return value
    }

    private static func optionalDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double, !value.isNaN { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber {
            let double = value.doubleValue
            return double.isNaN ? nil : double
        }
        return nil
    }

    private static func int64(_ raw: Any?) -> Int64? {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? Double { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

import CoreLocation
import CryptoKit
import FirebaseAuth
import Foundation
import SwiftUI
import UIKit

struct GroupHttpError: LocalizedError, Equatable {
    let statusCode: Int
    let code: String?
    let retryAfter: TimeInterval?

    var errorDescription: String? {
        switch code {
        case "GROUP_FULL":
            LocalizationHelper.localized("This group is full.")
        case "GROUP_NOT_FOUND":
            LocalizationHelper.localized("This group could not be found.")
        case "JOIN_RATE_LIMITED":
            LocalizationHelper.localized("Too many join attempts. Please wait and try again.")
        default:
            nil
        }
    }
}

enum GroupJoinClientError: LocalizedError, Equatable {
    case malformedCode
    case expired
    case signedOut

    var errorDescription: String? {
        switch self {
        case .malformedCode:
            LocalizationHelper.localized("Enter a valid 6-character join code.")
        case .expired:
            LocalizationHelper.localized("This invite has expired or the group has ended.")
        case .signedOut:
            LocalizationHelper.localized("Sign in to join a group")
        }
    }
}

@Observable
final class GroupRideManager {
    static let shared = GroupRideManager()

    private let store: GroupSessionStore
    private let session: URLSession
    private let errorLogger: ErrorLogger
    private var groupKey: SymmetricKey?
    private var backoff = GroupBackoff()
    private var syncTask: Task<Void, Never>?
    private var pendingPosition: String?
    private var pendingStatus: PendingStatusChange?
    private var statusUndoTask: Task<Void, Never>?
    private var statusUndoSnapshot: StatusUndoSnapshot?
    private var isSyncInFlight = false
    private var presencePauseStartedElapsedMillis: Int64?
    private var presencePauseCause: GroupPresencePolicy.Cause?
    private var lastPositionFixTimestamp: Date?

    private enum PendingStatusChange: Equatable {
        case set(envelope: String)
        case clear
    }

    private struct StatusUndoSnapshot {
        let status: RiderStatus?
        let ageAnchor: StatusAge.Anchor?
        let acknowledged: Bool
        let isClearing: Bool
        let pending: PendingStatusChange?
    }

    var state = GroupSessionState()
    var endNotice: GroupEndNotice?
    var pendingJoinToken: String?
    var pendingJoinCode: String?
    var pendingJoinViaCode = true
    /// Never persisted or sent on the wire. The route tail is presentation
    /// state rebuilt from newer server timestamps during this session (§3).
    private(set) var headingTails: [String: [GroupHeadingPoint]] = [:]
    private var latestHeadingServerTimestamps: [String: Int64] = [:]
    /// Kept outside session state so a notification tap cannot be erased by
    /// restore/teardown replacing the current session snapshot.
    var communityNavigationRequest = 0
    /// One-shot cross-tab navigation argument. It is intentionally not part of
    /// GroupSessionStore: it is a UI event, not group data (§4).
    var pendingMapFocusUID: String?
    var mapFocusRequest = 0

    init(
        store: GroupSessionStore = .shared,
        session: URLSession = .shared,
        errorLogger: ErrorLogger = CrashlyticsErrorLogger.shared
    ) {
        self.store = store
        self.session = session
        self.errorLogger = errorLogger
    }

    nonisolated deinit {}

    func requestMapFocus(uid: String) {
        pendingMapFocusUID = uid
        mapFocusRequest &+= 1
    }

    func consumeMapFocusUID() -> String? {
        defer { pendingMapFocusUID = nil }
        return pendingMapFocusUID
    }

    private static let headingTailWindowMillis: Int64 = 60_000
    private static let headingTailMaximumPoints = 10

    private func recordHeadingTails(
        positions: [GroupWire.MemberPosition],
        selfUID: String,
        receivedAtElapsedMillis: Int64
    ) {
        let currentUIDs = Set(positions.map(\.uid))
        headingTails = headingTails.filter { currentUIDs.contains($0.key) && $0.key != selfUID }
        latestHeadingServerTimestamps = latestHeadingServerTimestamps.filter {
            currentUIDs.contains($0.key) && $0.key != selfUID
        }

        for position in positions where position.uid != selfUID {
            guard position.moving, position.riding else {
                headingTails[position.uid] = []
                latestHeadingServerTimestamps[position.uid] = position.serverTsMillis
                continue
            }
            guard position.serverTsMillis > (latestHeadingServerTimestamps[position.uid] ?? Int64.min) else {
                // Idempotent sync responses must not manufacture a stationary
                // tail by repeating the same position (§3).
                continue
            }
            latestHeadingServerTimestamps[position.uid] = position.serverTsMillis
            var points = headingTails[position.uid, default: []]
            points.append(
                GroupHeadingPoint(
                    uid: position.uid,
                    latitude: position.lat,
                    longitude: position.lng,
                    serverTsMillis: position.serverTsMillis,
                    receivedAtElapsedMillis: receivedAtElapsedMillis
                )
            )
            points = points
                .filter { receivedAtElapsedMillis - $0.receivedAtElapsedMillis <= Self.headingTailWindowMillis }
                .suffix(Self.headingTailMaximumPoints)
                .map { $0 }
            headingTails[position.uid] = points
        }
    }

    func headingTailSegments(
        nowElapsedMillis: Int64,
        selfUID: String?
    ) -> [GroupHeadingTailSegment] {
        let movingByUID = Dictionary(uniqueKeysWithValues: state.positions.map { ($0.uid, $0) })
        return headingTails
            .filter { $0.key != selfUID }
            .flatMap { uid, points in
                guard let current = movingByUID[uid], current.moving, current.riding,
                      let anchor = current.ageAnchor, anchor.isKnown,
                      StatusAge.currentAgeMillis(anchor: anchor, nowElapsedMillis: nowElapsedMillis)
                        < Int64(max(20, state.syncIntervalSec * 2)) * 1_000 else {
                    return [GroupHeadingTailSegment]()
                }
                let livePoints = points.filter {
                    nowElapsedMillis - $0.receivedAtElapsedMillis <= Self.headingTailWindowMillis
                }
                guard livePoints.count >= 2 else { return [GroupHeadingTailSegment]() }
                let oldestToNewest = livePoints
                return (0 ..< oldestToNewest.count - 1).map { index in
                    let start = oldestToNewest[index]
                    let end = oldestToNewest[index + 1]
                    let ageFraction = Double(index) / Double(max(1, oldestToNewest.count - 2))
                    return GroupHeadingTailSegment(
                        uid: uid,
                        start: start.coordinate,
                        end: end.coordinate,
                        opacity: 0.16 + (0.84 * ageFraction),
                        lineWidth: 2.0 + (3.0 * ageFraction)
                    )
                }
            }
    }

    @discardableResult
    func restore() -> Bool {
        guard let restored = store.load() else { return false }
        do {
            groupKey = try GroupCrypto.deriveGroupKey(token: restored.token)
            let nowElapsed = StatusAge.elapsedMillis()
            state = GroupSessionState(
                status: .degraded,
                groupId: restored.record.groupId,
                joinCode: restored.record.joinCode,
                inviteToken: restored.token,
                isLeader: restored.record.isLeader,
                hasStarted: restored.record.hasStarted,
                expiresAtMillis: restored.record.expiresAtMillis,
                maxMembers: restored.record.maxMembers,
                rev: restored.record.rev,
                degradedSince: Date(),
                joinedAtElapsedMillis: nowElapsed,
                lastSuccessfulSyncElapsedMillis: nowElapsed,
                lastSyncFailureKind: .serviceUnavailable,
                alertsMuted: restored.record.alertsMuted
            )
            try restoreStatus(restored.record.status)
            refreshLocationSource()
            startSyncLoop()
            return true
        } catch {
            store.clear()
            groupKey = nil
            state = GroupSessionState()
            return false
        }
    }

    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme == "trackme" || url.host == "trackme.shvms.in" else { return false }
        var accepted = false
        if url.scheme == "trackme", url.host == "group" || url.path == "/group" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let token = items.first(where: { $0.name == "t" || $0.name == "token" })?.value
            let code = items.first(where: { $0.name == "c" || $0.name == "code" })?.value
            if let token, !token.isEmpty {
                pendingJoinToken = token
                pendingJoinCode = nil
            } else if let code, !code.isEmpty {
                pendingJoinToken = nil
                pendingJoinCode = code
            }
            pendingJoinViaCode = false
            accepted = pendingJoinToken != nil || pendingJoinCode != nil
        }
        if !accepted, (url.path == "/g" || url.path.hasPrefix("/g/")) {
            let fragment = url.fragment
            if let fragment, !fragment.isEmpty {
                pendingJoinToken = fragment
                pendingJoinCode = nil
                pendingJoinViaCode = false
                accepted = true
            }
        }
        if accepted {
            TelemetryManager.shared.trackGroupInviteOpened(viaCode: false)
        }
        return accepted
    }

    func inviteShareURL() -> URL? {
        guard let token = state.inviteToken else { return nil }
        return URL(string: "\(APIConfig.baseURL)/g/#\(token)")
    }

    func noteJoinCodeEdited(_ value: String) {
        if let pendingJoinCode, value == pendingJoinCode { return }
        pendingJoinCode = nil
        pendingJoinToken = nil
        pendingJoinViaCode = true
    }

    func createGroup(
        groupName: String,
        durationMinutes: Int = 240,
        maxMembers: Int = 5,
        destinationLat: Double? = nil,
        destinationLng: Double? = nil,
        startAtMillis: Int64? = nil
    ) async throws {
        let user = try currentUser()
        let token = try GroupCrypto.generateInviteToken()
        let key = try GroupCrypto.deriveGroupKey(token: token)
        let code = try GroupCrypto.generateJoinCode()
        let displayName = user.displayName
        let rosterPlain = try GroupWire.encodeRoster(
            displayName: displayName,
            initials: GroupWire.initials(for: displayName),
            photoUrl: user.photoURL?.absoluteString
        )
        let metaPlain = try GroupWire.encodeMeta(
            name: groupName,
            ownerDisplayName: displayName,
            destLat: destinationLat,
            destLng: destinationLng,
            startAtMillis: startAtMillis
        )
        let body: [String: Any] = [
            "tokenHash": try GroupCrypto.groupTokenHash(token),
            "joinCode": code,
            "wrappedToken": try GroupCrypto.wrapTokenForCode(joinCode: code, token: token),
            "durationMinutes": durationMinutes,
            "maxMembers": maxMembers,
            "meta": try GroupCrypto.seal(key: key, plaintext: metaPlain, purpose: .meta),
            "roster": try GroupCrypto.seal(key: key, plaintext: rosterPlain, purpose: .roster(uid: user.uid))
        ]
        let response = try await post(path: "/api/group/create", body: body)
        let created = try GroupWire.parseCreate(response)
        let joinedAtElapsed = StatusAge.elapsedMillis()
        try store.save(
            record: GroupSessionStore.Record(
                groupId: created.groupId,
                joinCode: created.joinCode,
                isLeader: true,
                expiresAtMillis: created.expiresAtMillis,
                maxMembers: created.maxMembers,
                rev: created.rev,
                hasStarted: created.state == "LIVE"
            ),
            token: token
        )
        groupKey = key
        state = GroupSessionState(
            status: statusFor(created.state),
            groupId: created.groupId,
            joinCode: created.joinCode,
            inviteToken: token,
            groupName: groupName,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
            startAtMillis: startAtMillis,
            isLeader: true,
            hasStarted: created.state == "LIVE",
            expiresAtMillis: created.expiresAtMillis,
            maxMembers: created.maxMembers,
            rev: created.rev,
            syncIntervalSec: created.syncIntervalSec,
            roster: [
                GroupWire.RosterEntry(
                    uid: user.uid,
                    displayName: displayName,
                    initials: GroupWire.initials(for: displayName),
                    photoUrl: user.photoURL?.absoluteString
                )
            ],
            joinedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            joinedAtElapsedMillis: joinedAtElapsed,
            lastSuccessfulSyncElapsedMillis: joinedAtElapsed
        )
        GroupReminderScheduler.schedule(groupId: created.groupId, groupName: groupName, startAtMillis: startAtMillis)
        refreshLocationSource()
        TelemetryManager.shared.trackGroupCreated(
            durationMinutes: durationMinutes,
            maxMembers: maxMembers,
            hasDestination: destinationLat != nil && destinationLng != nil,
            hasStartTime: startAtMillis != nil
        )
        startSyncLoop()
    }

    func joinByCode(_ rawCode: String, viaCode: Bool = true) async throws {
        if viaCode {
            TelemetryManager.shared.trackGroupInviteOpened(viaCode: true)
        }
        do {
            guard let code = GroupCrypto.normalizeJoinCode(rawCode) else {
                throw GroupJoinClientError.malformedCode
            }
            let resolved = try GroupWire.parseResolve(try await get(path: "/api/group/resolve?c=\(code)", authenticated: false))
            guard let wrapped = resolved.wrappedToken else { throw GroupJoinClientError.expired }
            let token = try GroupCrypto.unwrapTokenWithCode(joinCode: code, wrapped: wrapped)
            try await joinWithToken(token, joinCode: code, groupId: resolved.groupId, viaCode: viaCode)
        } catch {
            TelemetryManager.shared.trackGroupJoinFailed(
                reason: Self.classifyJoinFailure(error),
                viaCode: viaCode
            )
            throw error
        }
    }

    func joinByToken(_ token: String) async throws {
        do {
            let hash = try GroupCrypto.groupTokenHash(token)
            let resolved = try GroupWire.parseResolve(try await get(path: "/api/group/resolve?t=\(hash)", authenticated: false))
            try await joinWithToken(token, joinCode: resolved.joinCode ?? "", groupId: resolved.groupId, viaCode: false)
        } catch {
            TelemetryManager.shared.trackGroupJoinFailed(
                reason: Self.classifyJoinFailure(error),
                viaCode: false
            )
            throw error
        }
    }

    func startGroup() async throws {
        guard let groupId = state.groupId, let key = groupKey else {
            throw GroupWire.Error.missingField("groupId or groupKey")
        }

        var body: [String: Any] = ["groupId": groupId, "state": "LIVE"]
        var automaticStartAtMillis: Int64?
        if state.startAtMillis == nil {
            let startedAtMillis = Int64(Date().timeIntervalSince1970 * 1_000)
            let metaPlain = try GroupWire.encodeMeta(
                name: state.groupName ?? "Group Ride",
                ownerDisplayName: Auth.auth().currentUser?.displayName,
                destLat: state.destinationLat,
                destLng: state.destinationLng,
                startAtMillis: startedAtMillis
            )
            body["meta"] = try GroupCrypto.seal(key: key, plaintext: metaPlain, purpose: .meta)
            automaticStartAtMillis = startedAtMillis
        }

        let started = try GroupWire.parseState(
            try await post(path: "/api/group/state", body: body),
            key: key
        )
        state.status = .live
        state.hasStarted = true
        if let expiresAtMillis = started.expiresAtMillis {
            state.expiresAtMillis = expiresAtMillis
        }
        if let acceptedMeta = started.meta {
            state.groupName = acceptedMeta.name
            state.destinationLat = acceptedMeta.destLat
            state.destinationLng = acceptedMeta.destLng
            state.startAtMillis = acceptedMeta.startAtMillis
        } else if let automaticStartAtMillis, started.metaUpdated {
            // Backward-compatible fallback for a rollout relay that acknowledges the write but
            // does not yet echo the accepted encrypted meta.
            state.startAtMillis = automaticStartAtMillis
        }
        if let rev = started.rev { state.rev = rev }
        store.updateLifecycle(
            expiresAtMillis: state.expiresAtMillis,
            hasStarted: true,
            rev: started.rev
        )
        TelemetryManager.shared.trackGroupStarted(memberCount: state.memberCount)
    }

    func endGroup() async throws {
        try await setState("ENDED")
        TelemetryManager.shared.trackGroupEnded()
        teardown(notice: GroupEndNotice(reason: .ended, rideStillRecording: TrackingManager.shared.currentRideId != nil))
    }

    func updateMeta(destinationLat: Double?, destinationLng: Double?, startAtMillis: Int64?) async throws {
        guard state.isLeader, let groupId = state.groupId, let key = groupKey else {
            throw GroupWire.Error.missingField("groupId")
        }
        let effectiveStartAtMillis = state.hasStarted ? state.startAtMillis : startAtMillis
        let metaPlain = try GroupWire.encodeMeta(
            name: state.groupName ?? "Group Ride",
            ownerDisplayName: Auth.auth().currentUser?.displayName,
            destLat: destinationLat,
            destLng: destinationLng,
            startAtMillis: effectiveStartAtMillis
        )
        let envelope = try GroupCrypto.seal(key: key, plaintext: metaPlain, purpose: .meta)
        _ = try await post(path: "/api/group/meta", body: ["groupId": groupId, "meta": envelope])
        state.destinationLat = destinationLat
        state.destinationLng = destinationLng
        state.startAtMillis = effectiveStartAtMillis
        TelemetryManager.shared.trackGroupMetaUpdated(
            hasDestination: destinationLat != nil && destinationLng != nil,
            hasStartTime: effectiveStartAtMillis != nil
        )
        GroupReminderScheduler.schedule(
            groupId: groupId,
            groupName: state.groupName ?? "Group Ride",
            startAtMillis: effectiveStartAtMillis
        )
    }

    func removeMember(uid: String) async throws {
        guard state.isLeader, let groupId = state.groupId else { throw GroupWire.Error.missingField("groupId") }
        _ = try await post(path: "/api/group/remove", body: ["groupId": groupId, "uid": uid])
        state.positions.removeAll { $0.uid == uid }
        state.statuses.removeAll { $0.uid == uid }
        state.roster.removeAll { $0.uid == uid }
        TelemetryManager.shared.trackGroupMemberRemoved(memberCount: state.roster.count)
    }

    func leaveGroup() async {
        let groupId = state.groupId
        teardown(notice: nil)
        guard let groupId else { return }
        _ = try? await post(path: "/api/group/leave", body: ["groupId": groupId])
        TelemetryManager.shared.trackGroupLeft()
    }

    func updateLatestLocation(_ location: CLLocation?, moving: Bool, riding: Bool) {
        guard state.isActive, let key = groupKey, let uid = Auth.auth().currentUser?.uid else { return }
        guard let location else {
            pendingPosition = nil
            state.isSharingPosition = false
            return
        }
        let horizontalAccuracy = location.horizontalAccuracy
        guard horizontalAccuracy >= 0, horizontalAccuracy <= 150 else { return }
        let fixAge = Date().timeIntervalSince(location.timestamp)
        let maximumAcceptedAge = TimeInterval(max(30, state.syncIntervalSec * 2))
        guard fixAge >= -60, fixAge <= maximumAcceptedAge else { return }
        if let lastPositionFixTimestamp, location.timestamp <= lastPositionFixTimestamp { return }
        lastPositionFixTimestamp = location.timestamp
        do {
            let plain = try GroupWire.encodePosition(
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedMps: location.speed >= 0 ? location.speed : nil,
                headingDeg: location.course >= 0 ? location.course : nil,
                batteryPercent: batteryPercent(),
                moving: moving,
                riding: riding
            )
            pendingPosition = try GroupCrypto.seal(key: key, plaintext: plain, purpose: .position(uid: uid))
            state.isSharingPosition = true
        } catch {
            pendingPosition = nil
            state.isSharingPosition = false
        }
    }

    func acknowledgeEndNotice() {
        endNotice = nil
    }

    func setStatus(_ status: RiderStatus) throws {
        guard state.isActive else { throw GroupWire.Error.missingField("activeGroup") }
        if state.selfStatus?.raw == status.raw, !state.isClearingStatus { return }

        statusUndoTask?.cancel()
        statusUndoTask = nil
        statusUndoSnapshot = nil

        let setAtElapsed = StatusAge.elapsedMillis()
        if status.isAlert {
            statusUndoSnapshot = StatusUndoSnapshot(
                status: state.selfStatus,
                ageAnchor: state.selfStatusAgeAnchor,
                acknowledged: state.isSelfStatusAcknowledged,
                isClearing: state.isClearingStatus,
                pending: pendingStatus
            )
            state.selfStatus = status
            state.selfStatusAgeAnchor = StatusAge.Anchor(
                ageAtReceiptMillis: 0,
                receivedAtElapsedMillis: setAtElapsed,
                isKnown: true
            )
            state.isSelfStatusAcknowledged = false
            state.isClearingStatus = false
            state.isStatusUndoAvailable = true
            statusUndoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.commitStatusSet(
                        status,
                        setAtElapsedMillis: setAtElapsed,
                        ageKnown: true,
                        trackTelemetry: true
                    )
                }
            }
        } else {
            commitStatusSet(
                status,
                setAtElapsedMillis: setAtElapsed,
                ageKnown: true,
                trackTelemetry: true
            )
        }
        statusConfirmationHaptic()
    }

    func undoPendingAlertStatus() {
        guard state.isStatusUndoAvailable, let snapshot = statusUndoSnapshot else { return }
        statusUndoTask?.cancel()
        statusUndoTask = nil
        statusUndoSnapshot = nil
        state.selfStatus = snapshot.status
        state.selfStatusAgeAnchor = snapshot.ageAnchor
        state.isSelfStatusAcknowledged = snapshot.acknowledged
        state.isClearingStatus = snapshot.isClearing
        state.isStatusUndoAvailable = false
        pendingStatus = snapshot.pending
        statusConfirmationHaptic()
    }

    func clearStatus() {
        guard state.isActive, state.selfStatus != nil else { return }
        statusUndoTask?.cancel()
        statusUndoTask = nil
        statusUndoSnapshot = nil
        state.isStatusUndoAvailable = false
        state.isClearingStatus = true
        state.isSelfStatusAcknowledged = false
        pendingStatus = .clear
        persistCurrentStatus(pendingOperation: .clear)
        statusConfirmationHaptic()
        TelemetryManager.shared.trackGroupStatusCleared(byUser: true)
        requestImmediateSync()
    }

    func setAlertsMuted(_ muted: Bool) {
        state.alertsMuted = muted
        store.updateAlertsMuted(muted)
        if muted { TelemetryManager.shared.trackGroupStatusAlertMuted() }
    }

    func requestCommunityNavigation() {
        communityNavigationRequest &+= 1
    }

    func presencePill(nowElapsedMillis: Int64 = StatusAge.elapsedMillis()) -> GroupPresencePolicy.Pill {
        let statusAge = state.selfStatusAgeAnchor.map {
            StatusAge.bucket(anchor: $0, nowElapsedMillis: nowElapsedMillis, syncIntervalSec: state.syncIntervalSec)
        } ?? .unknown
        return GroupPresencePolicy.evaluate(.init(
            sessionActive: state.isActive,
            lastSuccessfulSyncElapsedMillis: state.lastSuccessfulSyncElapsedMillis,
            lastOwnPositionAckElapsedMillis: state.lastOwnPositionAckElapsedMillis,
            lastFailureKind: state.lastSyncFailureKind,
            isSharingPosition: state.isSharingPosition,
            isRideRecording: TrackingManager.shared.currentRideId != nil,
            selfStatus: state.selfStatus,
            selfStatusAge: statusAge,
            selfStatusAcknowledged: state.isSelfStatusAcknowledged,
            isClearingStatus: state.isClearingStatus,
            syncIntervalSec: state.syncIntervalSec,
            nowElapsedMillis: nowElapsedMillis
        ))
    }

    func observePresencePill(
        _ pill: GroupPresencePolicy.Pill,
        nowElapsedMillis: Int64 = StatusAge.elapsedMillis()
    ) {
        let cause: GroupPresencePolicy.Cause? = switch pill {
        case .paused(let cause, _, _), .pausedWithPendingStatus(let cause, _, _, _): cause
        default: nil
        }
        if let cause {
            if presencePauseStartedElapsedMillis == nil {
                presencePauseStartedElapsedMillis = nowElapsedMillis
            }
            presencePauseCause = cause
        } else {
            finishPresencePause(nowElapsedMillis: nowElapsedMillis)
        }
    }

    private func joinWithToken(_ token: String, joinCode: String, groupId: String, viaCode: Bool) async throws {
        let user = try currentUser()
        let key = try GroupCrypto.deriveGroupKey(token: token)
        let roster = try GroupWire.encodeRoster(
            displayName: user.displayName,
            initials: GroupWire.initials(for: user.displayName),
            photoUrl: user.photoURL?.absoluteString
        )
        let body: [String: Any] = [
            "groupId": groupId,
            "tokenHash": try GroupCrypto.groupTokenHash(token),
            "roster": try GroupCrypto.seal(key: key, plaintext: roster, purpose: .roster(uid: user.uid)),
            "viaCode": viaCode
        ]
        let joined = try GroupWire.parseJoin(try await post(path: "/api/group/join", body: body), key: key)
        let joinedAtElapsed = StatusAge.elapsedMillis()
        try store.save(
            record: GroupSessionStore.Record(
                groupId: joined.groupId,
                joinCode: joinCode,
                isLeader: false,
                expiresAtMillis: joined.expiresAtMillis,
                maxMembers: joined.maxMembers,
                rev: joined.rev,
                hasStarted: joined.state == "LIVE"
            ),
            token: token
        )
        groupKey = key
        state = GroupSessionState(
            status: statusFor(joined.state),
            groupId: joined.groupId,
            joinCode: joinCode,
            inviteToken: token,
            groupName: joined.meta?.name,
            destinationLat: joined.meta?.destLat,
            destinationLng: joined.meta?.destLng,
            startAtMillis: joined.meta?.startAtMillis,
            isLeader: false,
            hasStarted: joined.state == "LIVE",
            expiresAtMillis: joined.expiresAtMillis,
            maxMembers: joined.maxMembers,
            rev: joined.rev,
            syncIntervalSec: joined.syncIntervalSec,
            joinedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            joinedAtElapsedMillis: joinedAtElapsed,
            lastSuccessfulSyncElapsedMillis: joinedAtElapsed
        )
        GroupReminderScheduler.schedule(
            groupId: joined.groupId,
            groupName: joined.meta?.name ?? "Group Ride",
            startAtMillis: joined.meta?.startAtMillis
        )
        refreshLocationSource()
        TelemetryManager.shared.trackGroupMemberJoined(memberCount: joined.memberCount, viaCode: viaCode)
        startSyncLoop()
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncOnce()
                let interval = max(1, self.state.syncIntervalSec)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    @MainActor
    private func syncOnce() async {
        guard !isSyncInFlight, state.isActive, let groupId = state.groupId, let key = groupKey else { return }
        isSyncInFlight = true
        defer { isSyncInFlight = false }
        let sentPosition = pendingPosition
        let sentStatus = pendingStatus
        do {
            var body: [String: Any] = [
                "groupId": groupId,
                "moving": TrackingManager.shared.currentSpeed > 0.5,
                "foreground": UIApplication.shared.applicationState == .active,
                "rev": state.roster.isEmpty ? -1 : state.rev
            ]
            if let sentPosition { body["pos"] = sentPosition }
            switch sentStatus {
            case .set(let envelope):
                body.merge(GroupWire.statusRequestFields(for: .set(envelope: envelope))) { _, new in new }
            case .clear:
                body.merge(GroupWire.statusRequestFields(for: .clear)) { _, new in new }
            case nil:
                break
            }
            let data = try await post(path: "/api/group/sync", body: body)
            let selfUID = try currentUser().uid
            let result = try GroupWire.parseSync(data, key: key, selfUid: selfUID)
            apply(sync: result, sentPosition: sentPosition, sentStatus: sentStatus, selfUID: selfUID)
            backoff.reset()
        } catch let error as GroupHttpError {
            await handleSyncHTTPError(error)
        } catch {
            await enterDegraded(error: error)
        }
    }

    @MainActor
    private func apply(
        sync: GroupWire.SyncResult,
        sentPosition: String?,
        sentStatus: PendingStatusChange?,
        selfUID: String
    ) {
        if sync.state == "ENDED" {
            teardown(notice: GroupEndNotice(reason: .ended, rideStillRecording: TrackingManager.shared.currentRideId != nil))
            return
        }
        let previousExpiry = state.expiresAtMillis
        let wasStarted = state.hasStarted
        state.status = statusFor(sync.state)
        state.hasStarted = sync.state == "LIVE"
        state.expiresAtMillis = sync.expiresAtMillis
        state.rev = sync.rev
        state.maxMembers = sync.maxMembers
        state.syncIntervalSec = sync.nextSyncInSec
        state.positions = sync.positions
        let acceptedAtElapsed = StatusAge.elapsedMillis()
        recordHeadingTails(
            positions: sync.positions,
            selfUID: selfUID,
            receivedAtElapsedMillis: acceptedAtElapsed
        )
        state.lastSuccessfulSyncElapsedMillis = acceptedAtElapsed
        state.lastSyncFailureKind = nil
        state.consecutiveFailures = 0
        state.degradedSince = nil
        if previousExpiry != state.expiresAtMillis || wasStarted != state.hasStarted {
            store.updateLifecycle(
                expiresAtMillis: state.expiresAtMillis,
                hasStarted: state.hasStarted
            )
        }

        if let sentPosition,
           sync.selfPositionAck?.envelope == sentPosition {
            state.lastOwnPositionAckElapsedMillis = acceptedAtElapsed
            if pendingPosition == sentPosition { pendingPosition = nil }
        }

        if sync.statusesFieldPresent {
            let receivedStatusUIDs = Set(sync.statuses.map(\.uid))
            let effectiveStatuses = sync.statuses + state.statuses.filter {
                sync.unreadableStatusUIDs.contains($0.uid) && !receivedStatusUIDs.contains($0.uid)
            }
            let alertRoster: [GroupWire.RosterEntry]
            if let currentRoster = sync.roster {
                let currentUIDs = Set(currentRoster.map(\.uid))
                alertRoster = currentRoster + state.roster.filter { !currentUIDs.contains($0.uid) }
            } else {
                alertRoster = state.roster
            }
            GroupStatusAlertCoordinator.shared.process(
                previous: state.statuses,
                current: effectiveStatuses,
                positions: sync.positions,
                roster: alertRoster,
                groupName: state.groupName,
                joinedAtElapsedMillis: state.joinedAtElapsedMillis,
                syncIntervalSec: state.syncIntervalSec,
                alertsMuted: state.alertsMuted
            )
            state.statuses = effectiveStatuses
        }

        switch sentStatus {
        case .set(let envelope)
            where pendingStatus == sentStatus && sync.selfStatusAck?.envelope == envelope:
            state.selfStatus = sync.selfStatus?.status ?? state.selfStatus
            state.selfStatusAgeAnchor = sync.selfStatus?.ageAnchor ?? state.selfStatusAgeAnchor
            state.isSelfStatusAcknowledged = true
            state.isClearingStatus = false
            state.lastStatusAckElapsedMillis = acceptedAtElapsed
            if pendingStatus == sentStatus { pendingStatus = nil }
            persistCurrentStatus(pendingOperation: nil)
        case .clear
            where pendingStatus == sentStatus && sync.statusesFieldPresent && sync.selfStatus == nil:
            state.lastStatusAckElapsedMillis = acceptedAtElapsed
            state.selfStatus = nil
            state.selfStatusAgeAnchor = nil
            state.isSelfStatusAcknowledged = true
            state.isClearingStatus = false
            if pendingStatus == sentStatus { pendingStatus = nil }
            store.updateStatus(nil)
        default:
            if pendingStatus == nil, let selfStatus = sync.selfStatus {
                state.selfStatus = selfStatus.status
                state.selfStatusAgeAnchor = selfStatus.ageAnchor
                state.isSelfStatusAcknowledged = true
                if let envelope = sync.selfStatusAck?.envelope {
                    persistAcknowledgedSelfStatus(
                        selfStatus,
                        envelope: envelope,
                        acceptedAtElapsedMillis: acceptedAtElapsed
                    )
                }
            } else if pendingStatus == nil,
                      sync.statusesFieldPresent,
                      state.selfStatus != nil,
                      let stored = store.load()?.record.status,
                      let envelope = stored.envelope {
                pendingStatus = .set(envelope: envelope)
                state.isSelfStatusAcknowledged = false
                persistCurrentStatus(pendingOperation: .set)
            }
        }
        if let roster = sync.roster {
            state.roster = roster
            store.updateRev(sync.rev)
        }
        if let meta = sync.meta {
            let metaChanged = state.groupName != meta.name || state.startAtMillis != meta.startAtMillis
            state.groupName = meta.name
            state.destinationLat = meta.destLat
            state.destinationLng = meta.destLng
            state.startAtMillis = meta.startAtMillis
            if metaChanged, let groupId = state.groupId {
                GroupReminderScheduler.schedule(
                    groupId: groupId,
                    groupName: meta.name ?? "Group Ride",
                    startAtMillis: meta.startAtMillis
                )
            }
        }
        if !sync.undecryptable.isEmpty || !sync.unreadableStatusUIDs.isEmpty {
            errorLogger.log("GroupRide: skipped unreadable member envelopes")
        }
    }

    private func handleSyncHTTPError(_ error: GroupHttpError) async {
        if error.statusCode == 403 {
            await MainActor.run {
                teardown(notice: GroupEndNotice(reason: .removed, rideStillRecording: TrackingManager.shared.currentRideId != nil))
            }
        } else if error.statusCode == 404 {
            await MainActor.run {
                teardown(notice: GroupEndNotice(reason: .expired, rideStillRecording: TrackingManager.shared.currentRideId != nil))
            }
        } else if GroupBackoff.isRetryable(statusCode: error.statusCode, code: error.code) {
            await enterDegraded(error: error, retryAfter: error.retryAfter)
        } else {
            await enterDegraded(error: error)
        }
    }

    @MainActor
    private func enterDegraded(error: Error, retryAfter: TimeInterval? = nil) async {
        errorLogger.recordError(error)
        state.status = .degraded
        state.degradedSince = state.degradedSince ?? Date()
        state.consecutiveFailures += 1
        state.lastSyncFailureKind = classifySyncFailure(error)
        TelemetryManager.shared.trackGroupDegraded()
        let delay = backoff.nextDelay(retryAfter: retryAfter)
        try? await Task.sleep(for: .seconds(delay))
    }

    private func teardown(notice: GroupEndNotice?) {
        let groupEnded = notice?.reason == .ended || notice?.reason == .expired
        if state.selfStatus != nil,
           !state.isStatusUndoAvailable,
           groupEnded {
            TelemetryManager.shared.trackGroupStatusCleared(byUser: false)
        }
        finishPresencePause(nowElapsedMillis: StatusAge.elapsedMillis())
        syncTask?.cancel()
        syncTask = nil
        GroupPresenceLocationProvider.shared.stop()
        GroupReminderScheduler.cancel()
        GroupStatusAlertCoordinator.shared.removeSessionNotifications()
        store.clear()
        groupKey = nil
        pendingPosition = nil
        pendingStatus = nil
        lastPositionFixTimestamp = nil
        headingTails.removeAll()
        latestHeadingServerTimestamps.removeAll()
        statusUndoTask?.cancel()
        statusUndoTask = nil
        statusUndoSnapshot = nil
        state = GroupSessionState()
        endNotice = notice
    }

    private func finishPresencePause(nowElapsedMillis: Int64) {
        guard let started = presencePauseStartedElapsedMillis,
              let cause = presencePauseCause else { return }
        let duration = max(0, nowElapsedMillis - started)
        let bucket: String
        switch duration {
        case ..<120_000: bucket = "under_2m"
        case ..<600_000: bucket = "2_to_10m"
        default: bucket = "10m_plus"
        }
        TelemetryManager.shared.trackGroupPresencePaused(durationBucket: bucket, cause: cause)
        presencePauseStartedElapsedMillis = nil
        presencePauseCause = nil
    }

    private func setState(_ next: String) async throws {
        guard let groupId = state.groupId else { throw GroupWire.Error.missingField("groupId") }
        _ = try await post(path: "/api/group/state", body: ["groupId": groupId, "state": next])
    }

    private func get(path: String, authenticated: Bool) async throws -> Data {
        var request = URLRequest(url: try url(path))
        request.timeoutInterval = 15
        if authenticated {
            try await applyAuth(&request)
        }
        return try await send(request, retry401: authenticated)
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await applyAuth(&request)
        return try await send(request, retry401: true)
    }

    private func send(_ request: URLRequest, retry401: Bool) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try validate(data: data, response: response, request: request)
            return data
        } catch let error as GroupHttpError where retry401 && error.statusCode == 401 {
            var refreshedRequest = request
            try await applyRefreshedAuth(&refreshedRequest)
            let (data, response) = try await session.data(for: refreshedRequest)
            try validate(data: data, response: response, request: refreshedRequest)
            return data
        }
    }

    private func validate(data: Data, response: URLResponse, request: URLRequest) throws {
        guard let http = response as? HTTPURLResponse else { throw GroupWire.Error.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw GroupHttpError(
                statusCode: http.statusCode,
                code: GroupWire.errorCode(data),
                retryAfter: retryAfter
            )
        }
    }

    private func applyAuth(_ request: inout URLRequest) async throws {
        let token = try await idToken(forceRefresh: false)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func applyRefreshedAuth(_ request: inout URLRequest) async throws {
        let token = try await idToken(forceRefresh: true)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    func refreshLocationSource() {
        guard state.isActive else {
            GroupPresenceLocationProvider.shared.stop()
            return
        }
        if TrackingManager.shared.currentRideId == nil {
            GroupPresenceLocationProvider.shared.start()
        } else {
            GroupPresenceLocationProvider.shared.stop()
        }
    }

    private func idToken(forceRefresh: Bool) async throws -> String {
        let user = try currentUser()
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GroupWire.Error.missingField("idToken"))
                }
            }
        }
    }

    private func currentUser() throws -> User {
        guard let user = Auth.auth().currentUser else { throw GroupJoinClientError.signedOut }
        return user
    }

    static func classifyJoinFailure(_ error: Error) -> GroupJoinFailure {
        if let clientError = error as? GroupJoinClientError {
            switch clientError {
            case .malformedCode: return .malformedCode
            case .expired: return .expired
            case .signedOut: return .signedOut
            }
        }
        if let httpError = error as? GroupHttpError {
            switch httpError.code {
            case "GROUP_FULL": return .groupFull
            case "GROUP_NOT_FOUND": return .groupNotFound
            case "JOIN_RATE_LIMITED": return .joinRateLimited
            default: return .unknown
            }
        }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return .network
        }
        return .unknown
    }

    private func url(_ path: String) throws -> URL {
        if path.hasPrefix("http"), let url = URL(string: path) { return url }
        guard let url = URL(string: "\(APIConfig.baseURL)\(path)") else { throw GroupWire.Error.malformedResponse }
        return url
    }

    private func statusFor(_ value: String) -> GroupSessionStatus {
        GroupSessionStatus(rawValue: value) ?? .preparing
    }

    private func batteryPercent() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    private func commitStatusSet(
        _ status: RiderStatus,
        setAtElapsedMillis: Int64,
        ageKnown: Bool,
        trackTelemetry: Bool
    ) {
        guard state.isActive, let key = groupKey, let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let nowElapsed = StatusAge.elapsedMillis()
            let ageSeconds = ageKnown ? max(0, nowElapsed - setAtElapsedMillis) / 1_000 : nil
            let plain = try GroupWire.encodeStatus(status, statusAgeSeconds: ageSeconds)
            let envelope = try GroupCrypto.seal(key: key, plaintext: plain, purpose: .status(uid: uid))
            pendingStatus = .set(envelope: envelope)
            state.selfStatus = status
            state.selfStatusAgeAnchor = ageKnown
                ? StatusAge.Anchor(
                    ageAtReceiptMillis: max(0, nowElapsed - setAtElapsedMillis),
                    receivedAtElapsedMillis: nowElapsed,
                    isKnown: true
                )
                : .unknown(receivedAtElapsedMillis: nowElapsed)
            state.isSelfStatusAcknowledged = false
            state.isClearingStatus = false
            state.isStatusUndoAvailable = false
            statusUndoSnapshot = nil
            statusUndoTask = nil
            let wallNow = Int64(Date().timeIntervalSince1970 * 1_000)
            store.updateStatus(.init(
                raw: status.raw,
                envelope: envelope,
                setAtElapsedMillis: ageKnown ? setAtElapsedMillis : nil,
                bootEpochAtSetMillis: ageKnown ? StatusAge.bootEpochMillis(wallNowMillis: wallNow, elapsedMillis: nowElapsed) : nil,
                pendingOperation: .set,
                acknowledged: false
            ))
            if trackTelemetry {
                TelemetryManager.shared.trackGroupStatusSet(severity: status.severity)
            }
            requestImmediateSync()
        } catch {
            errorLogger.recordError(error)
        }
    }

    private func restoreStatus(_ stored: GroupSessionStore.StoredStatus?) throws {
        guard let stored, let status = RiderStatusCodec.parse(stored.raw) else { return }
        let nowElapsed = StatusAge.elapsedMillis()
        let wallNow = Int64(Date().timeIntervalSince1970 * 1_000)
        let currentBoot = StatusAge.bootEpochMillis(wallNowMillis: wallNow, elapsedMillis: nowElapsed)
        let ageKnown = stored.setAtElapsedMillis != nil && stored.bootEpochAtSetMillis.map {
            !StatusAge.bootEpochChanged(stored: $0, current: currentBoot)
        } == true

        state.selfStatus = status
        state.selfStatusAgeAnchor = if ageKnown, let setAt = stored.setAtElapsedMillis {
            StatusAge.Anchor(
                ageAtReceiptMillis: max(0, nowElapsed - setAt),
                receivedAtElapsedMillis: nowElapsed,
                isKnown: true
            )
        } else {
            .unknown(receivedAtElapsedMillis: nowElapsed)
        }
        state.isSelfStatusAcknowledged = stored.acknowledged

        if stored.pendingOperation == .clear {
            pendingStatus = .clear
            state.isClearingStatus = true
            state.isSelfStatusAcknowledged = false
        } else if ageKnown, let envelope = stored.envelope, stored.pendingOperation == .set {
            pendingStatus = .set(envelope: envelope)
            state.isSelfStatusAcknowledged = false
        } else if !ageKnown {
            commitStatusSet(
                status,
                setAtElapsedMillis: nowElapsed,
                ageKnown: false,
                trackTelemetry: false
            )
        }
    }

    private func persistCurrentStatus(pendingOperation: GroupSessionStore.StatusOperation?) {
        guard let status = state.selfStatus else {
            store.updateStatus(nil)
            return
        }
        let existing = store.load()?.record.status
        let envelope: String? = switch pendingStatus {
        case .set(let envelope): envelope
        default: existing?.envelope
        }
        store.updateStatus(.init(
            raw: status.raw,
            envelope: envelope,
            setAtElapsedMillis: existing?.setAtElapsedMillis,
            bootEpochAtSetMillis: existing?.bootEpochAtSetMillis,
            pendingOperation: pendingOperation,
            acknowledged: state.isSelfStatusAcknowledged
        ))
    }

    private func persistAcknowledgedSelfStatus(
        _ memberStatus: GroupWire.MemberStatus,
        envelope: String,
        acceptedAtElapsedMillis: Int64
    ) {
        let age = memberStatus.ageAnchor.isKnown
            ? StatusAge.currentAgeMillis(
                anchor: memberStatus.ageAnchor,
                nowElapsedMillis: acceptedAtElapsedMillis
            )
            : nil
        let setAtElapsedMillis = age.map { value -> Int64 in
            let (result, overflow) = acceptedAtElapsedMillis.subtractingReportingOverflow(value)
            return overflow ? Int64.min : result
        }
        let wallNow = Int64(Date().timeIntervalSince1970 * 1_000)
        store.updateStatus(.init(
            raw: memberStatus.status.raw,
            envelope: envelope,
            setAtElapsedMillis: setAtElapsedMillis,
            bootEpochAtSetMillis: setAtElapsedMillis == nil
                ? nil
                : StatusAge.bootEpochMillis(
                    wallNowMillis: wallNow,
                    elapsedMillis: acceptedAtElapsedMillis
                ),
            pendingOperation: nil,
            acknowledged: true
        ))
    }

    private func requestImmediateSync() {
        Task { [weak self] in await self?.syncOnce() }
    }

    private func classifySyncFailure(_ error: Error) -> GroupSyncFailureKind {
        if !NetworkMonitor.shared.isConnected { return .noInternet }
        if let http = error as? GroupHttpError {
            if http.statusCode == 401 { return .auth }
            if http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                return .serviceUnavailable
            }
            return .protocolFailure
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
                 .dataNotAllowed, .callIsActive:
                return .noInternet
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .serviceUnavailable
            default:
                return .protocolFailure
            }
        }
        return .protocolFailure
    }

    private func statusConfirmationHaptic() {
        guard UIApplication.shared.applicationState == .active else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

import CoreLocation
import CryptoKit
import FirebaseAuth
import Foundation
import SwiftUI
import UIKit

struct GroupHttpError: Error, Equatable {
    let statusCode: Int
    let code: String?
    let retryAfter: TimeInterval?
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

    var state = GroupSessionState()
    var endNotice: GroupEndNotice?
    var pendingJoinToken: String?
    var pendingJoinCode: String?

    init(
        store: GroupSessionStore = .shared,
        session: URLSession = .shared,
        errorLogger: ErrorLogger = CrashlyticsErrorLogger.shared
    ) {
        self.store = store
        self.session = session
        self.errorLogger = errorLogger
    }

    @discardableResult
    func restore() -> Bool {
        guard let restored = store.load() else { return false }
        do {
            groupKey = try GroupCrypto.deriveGroupKey(token: restored.token)
            state = GroupSessionState(
                status: .degraded,
                groupId: restored.record.groupId,
                joinCode: restored.record.joinCode,
                inviteToken: restored.token,
                isLeader: restored.record.isLeader,
                expiresAtMillis: restored.record.expiresAtMillis,
                maxMembers: restored.record.maxMembers,
                rev: restored.record.rev,
                degradedSince: Date()
            )
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
        if url.scheme == "trackme", url.host == "group" || url.path == "/group" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            pendingJoinToken = items.first(where: { $0.name == "t" || $0.name == "token" })?.value
            pendingJoinCode = items.first(where: { $0.name == "c" || $0.name == "code" })?.value
            return pendingJoinToken != nil || pendingJoinCode != nil
        }
        if url.path == "/g" || url.path.hasPrefix("/g/") {
            let fragment = url.fragment
            if let fragment, !fragment.isEmpty {
                pendingJoinToken = fragment
                return true
            }
        }
        return false
    }

    func inviteShareURL() -> URL? {
        guard let token = state.inviteToken else { return nil }
        return URL(string: "\(APIConfig.baseURL)/g/#\(token)")
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
        try store.save(
            record: GroupSessionStore.Record(
                groupId: created.groupId,
                joinCode: created.joinCode,
                isLeader: true,
                expiresAtMillis: created.expiresAtMillis,
                maxMembers: created.maxMembers,
                rev: created.rev
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
            joinedAtMillis: Int64(Date().timeIntervalSince1970 * 1000)
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

    func joinByCode(_ rawCode: String) async throws {
        guard let code = GroupCrypto.normalizeJoinCode(rawCode) else { throw GroupCrypto.Error.invalidJoinCode }
        let resolved = try GroupWire.parseResolve(try await get(path: "/api/group/resolve?c=\(code)", authenticated: false))
        guard let wrapped = resolved.wrappedToken else { throw GroupWire.Error.missingField("wrappedToken") }
        let token = try GroupCrypto.unwrapTokenWithCode(joinCode: code, wrapped: wrapped)
        try await joinWithToken(token, joinCode: code, groupId: resolved.groupId, viaCode: true)
    }

    func joinByToken(_ token: String) async throws {
        let hash = try GroupCrypto.groupTokenHash(token)
        let resolved = try GroupWire.parseResolve(try await get(path: "/api/group/resolve?t=\(hash)", authenticated: false))
        try await joinWithToken(token, joinCode: resolved.joinCode ?? "", groupId: resolved.groupId, viaCode: false)
    }

    func startGroup() async throws {
        try await setState("LIVE")
        state.status = .live
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
        let metaPlain = try GroupWire.encodeMeta(
            name: state.groupName ?? "Group Ride",
            ownerDisplayName: Auth.auth().currentUser?.displayName,
            destLat: destinationLat,
            destLng: destinationLng,
            startAtMillis: startAtMillis
        )
        let envelope = try GroupCrypto.seal(key: key, plaintext: metaPlain, purpose: .meta)
        _ = try await post(path: "/api/group/meta", body: ["groupId": groupId, "meta": envelope])
        state.destinationLat = destinationLat
        state.destinationLng = destinationLng
        state.startAtMillis = startAtMillis
        GroupReminderScheduler.schedule(
            groupId: groupId,
            groupName: state.groupName ?? "Group Ride",
            startAtMillis: startAtMillis
        )
    }

    func removeMember(uid: String) async throws {
        guard state.isLeader, let groupId = state.groupId else { throw GroupWire.Error.missingField("groupId") }
        _ = try await post(path: "/api/group/remove", body: ["groupId": groupId, "uid": uid])
        state.positions.removeAll { $0.uid == uid }
        state.roster.removeAll { $0.uid == uid }
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
        guard horizontalAccuracy >= 0, horizontalAccuracy <= 150 else {
            pendingPosition = nil
            state.isSharingPosition = false
            return
        }
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
        try store.save(
            record: GroupSessionStore.Record(
                groupId: joined.groupId,
                joinCode: joinCode,
                isLeader: false,
                expiresAtMillis: joined.expiresAtMillis,
                maxMembers: joined.maxMembers,
                rev: joined.rev
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
            expiresAtMillis: joined.expiresAtMillis,
            maxMembers: joined.maxMembers,
            rev: joined.rev,
            syncIntervalSec: joined.syncIntervalSec,
            joinedAtMillis: Int64(Date().timeIntervalSince1970 * 1000)
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
        guard state.isActive, let groupId = state.groupId, let key = groupKey else { return }
        do {
            var body: [String: Any] = [
                "groupId": groupId,
                "moving": TrackingManager.shared.currentSpeed > 0.5,
                "foreground": UIApplication.shared.applicationState == .active,
                "rev": state.roster.isEmpty ? -1 : state.rev
            ]
            if let pendingPosition { body["pos"] = pendingPosition }
            let data = try await post(path: "/api/group/sync", body: body)
            let result = try GroupWire.parseSync(data, key: key, selfUid: try currentUser().uid)
            apply(sync: result)
            backoff.reset()
        } catch let error as GroupHttpError {
            await handleSyncHTTPError(error)
        } catch {
            await enterDegraded(error: error)
        }
    }

    @MainActor
    private func apply(sync: GroupWire.SyncResult) {
        if sync.state == "ENDED" {
            teardown(notice: GroupEndNotice(reason: .ended, rideStillRecording: TrackingManager.shared.currentRideId != nil))
            return
        }
        state.status = statusFor(sync.state)
        state.expiresAtMillis = sync.expiresAtMillis
        state.rev = sync.rev
        state.maxMembers = sync.maxMembers
        state.syncIntervalSec = sync.nextSyncInSec
        state.positions = sync.positions
        state.consecutiveFailures = 0
        state.degradedSince = nil
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
        if !sync.undecryptable.isEmpty {
            errorLogger.log("GroupRide: skipped undecryptable member envelopes")
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
        }
    }

    @MainActor
    private func enterDegraded(error: Error, retryAfter: TimeInterval? = nil) async {
        errorLogger.recordError(error)
        state.status = .degraded
        state.degradedSince = state.degradedSince ?? Date()
        state.consecutiveFailures += 1
        TelemetryManager.shared.trackGroupDegraded()
        let delay = backoff.nextDelay(retryAfter: retryAfter)
        try? await Task.sleep(for: .seconds(delay))
    }

    private func teardown(notice: GroupEndNotice?) {
        syncTask?.cancel()
        syncTask = nil
        GroupPresenceLocationProvider.shared.stop()
        GroupReminderScheduler.cancel()
        store.clear()
        groupKey = nil
        pendingPosition = nil
        state = GroupSessionState()
        endNotice = notice
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
        guard let user = Auth.auth().currentUser else { throw GroupWire.Error.missingField("currentUser") }
        return user
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
}

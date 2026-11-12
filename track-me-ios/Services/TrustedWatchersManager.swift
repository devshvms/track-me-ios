import Foundation
import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

struct TrustedWatcher: Identifiable, Equatable {
    let uid: String
    let displayName: String
    let photoUrl: String?
    let autoNotify: Bool
    let addedAtMillis: Int64

    var id: String { uid }
}

struct WatcherInboxInvite: Identifiable, Equatable {
    let sessionId: String
    let shareUrl: String
    let riderName: String
    let startedAt: Date?
    let expiresAt: Date?

    var id: String { sessionId }
}

struct ParsedWatcherInviteLink: Equatable {
    let inviterUid: String
    let inviterName: String?
}

/// Manages Trusted Watchers pairing (zero Contacts permission; invite-link & backend-verified),
/// FCM token registration in `users/{uid}`, and active incoming live-share watcher inbox.
@Observable
final class TrustedWatchersManager {
    static let shared = TrustedWatchersManager()
    static let maxWatchers = 5

    var watchers: [TrustedWatcher] = []
    var inboxInvite: WatcherInboxInvite?
    var pendingWatcherInvite: ParsedWatcherInviteLink?
    var pendingOpenSessionId: String?
    var pendingOpenShareURL: String?

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var watcherListener: ListenerRegistration?

    private init() {}

    func bindToAuth() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.watcherListener?.remove()
            self.watcherListener = nil
            if let user, !user.isAnonymous {
                self.attachWatcherListener(uid: user.uid)
                Task {
                    await self.syncCurrentUserFcmToken(uid: user.uid, displayName: user.displayName)
                    _ = await self.refreshInbox()
                }
            } else {
                DispatchQueue.main.async {
                    self.watchers = []
                    self.inboxInvite = nil
                }
            }
        }
    }

    private func attachWatcherListener(uid: String) {
        watcherListener?.remove()
        watcherListener = Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("trusted_watchers")
            .limit(to: Self.maxWatchers)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self, error == nil, let snapshot else { return }
                let items: [TrustedWatcher] = snapshot.documents.compactMap { doc in
                    let data = doc.data()
                    let rawUid = (data["uid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let watcherUid = (rawUid?.isEmpty == false ? rawUid : nil) ?? doc.documentID
                    guard !watcherUid.isEmpty else { return nil }
                    let rawName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = (rawName?.isEmpty == false ? rawName : nil) ?? "TrackMe Rider"
                    let photoUrl = (data["photoUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let autoNotify = (data["autoNotify"] as? Bool) ?? true
                    let addedAtMillis: Int64
                    if let num = data["addedAt"] as? NSNumber {
                        addedAtMillis = num.int64Value
                    } else if let ts = data["addedAt"] as? Timestamp {
                        addedAtMillis = Int64(ts.dateValue().timeIntervalSince1970 * 1000)
                    } else {
                        addedAtMillis = 0
                    }
                    return TrustedWatcher(
                        uid: watcherUid,
                        displayName: displayName,
                        photoUrl: photoUrl?.isEmpty == false ? photoUrl : nil,
                        autoNotify: autoNotify,
                        addedAtMillis: addedAtMillis
                    )
                }.sorted { $0.addedAtMillis < $1.addedAtMillis }

                DispatchQueue.main.async {
                    self.watchers = items
                }
            }
    }

    func syncFcmToken(_ token: String?) {
        guard let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty,
              let user = Auth.auth().currentUser,
              !user.isAnonymous else { return }
        Task {
            await writeUserTokenDoc(uid: user.uid, token: clean, displayName: user.displayName)
        }
    }

    private func syncCurrentUserFcmToken(uid: String, displayName: String?) async {
        let token = try? await Messaging.messaging().token()
        guard let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return }
        await writeUserTokenDoc(uid: uid, token: clean, displayName: displayName)
    }

    private func writeUserTokenDoc(uid: String, token: String, displayName: String?) async {
        var payload: [String: Any] = [
            "fcmToken": token,
            "updatedAt": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanName.isEmpty {
            payload["displayName"] = cleanName
        }
        try? await Firestore.firestore()
            .collection("users")
            .document(uid)
            .setData(payload, merge: true)
    }

    func buildCurrentUserInviteLink() -> String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return APIConfig.LiveShare.watcherInviteLink(inviterUid: user.uid, inviterName: user.displayName)
    }

    func setAutoNotify(watcherUid: String, enabled: Bool) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            try await Firestore.firestore()
                .collection("users")
                .document(uid)
                .collection("trusted_watchers")
                .document(watcherUid)
                .updateData(["autoNotify": enabled])
            return true
        } catch {
            return false
        }
    }

    func removeWatcher(watcherUid: String) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            try await Firestore.firestore()
                .collection("users")
                .document(uid)
                .collection("trusted_watchers")
                .document(watcherUid)
                .delete()
            TelemetryManager.shared.trackTrustedWatcherRemoved()
            return true
        } catch {
            return false
        }
    }

    func acceptWatcherInvite(inviterUid: String, inviterName: String?) async -> Result<Void, Error> {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            return .failure(NSError(domain: "TrustedWatchers", code: 401, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Sign in to accept this Trusted Watcher invite.")
            ]))
        }
        let cleanInviterUid = inviterUid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInviterUid.isEmpty, cleanInviterUid != user.uid else {
            return .failure(NSError(domain: "TrustedWatchers", code: 400, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Invalid watcher invite.")
            ]))
        }
        guard let url = URL(string: APIConfig.LiveShare.startSession) else {
            return .failure(NSError(domain: "TrustedWatchers", code: 0))
        }

        var body: [String: Any] = [
            "action": "accept_watcher",
            "inviterUid": cleanInviterUid,
        ]
        if let inviterName = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines), !inviterName.isEmpty {
            body["inviterName"] = inviterName
        }
        if let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            body["displayName"] = displayName
        }

        do {
            let (status, data) = try await postAuthenticated(url: url, user: user, body: body)
            if status == 200 {
                TelemetryManager.shared.trackTrustedWatcherAdded()
                return .success(())
            }
            if status == 409 {
                return .failure(NSError(domain: "TrustedWatchers", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: LocalizationHelper.localized("This rider already has 5 trusted watchers.")
                ]))
            }
            let serverError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            return .failure(NSError(domain: "TrustedWatchers", code: status, userInfo: [
                NSLocalizedDescriptionKey: serverError ?? LocalizationHelper.localized("Could not accept watcher invite.")
            ]))
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    func refreshInbox() async -> WatcherInboxInvite? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous,
              let url = URL(string: "\(APIConfig.LiveShare.startSession)?inbox=1") else {
            await MainActor.run { self.inboxInvite = nil }
            return nil
        }

        do {
            var token = try await fetchIdToken(user: user, forceRefresh: false)
            var (status, data) = try await getAuthenticated(url: url, token: token)
            if status == 401 {
                token = try await fetchIdToken(user: user, forceRefresh: true)
                (status, data) = try await getAuthenticated(url: url, token: token)
            }
            guard status == 200 else {
                return nil
            }
            let invite = Self.parseInboxInvite(from: data)
            await MainActor.run {
                self.inboxInvite = invite
            }
            return invite
        } catch {
            return nil
        }
    }

    func dismissInboxInvite() {
        inboxInvite = nil
    }

    func setPendingWatcherInvite(_ invite: ParsedWatcherInviteLink?) {
        pendingWatcherInvite = invite
    }

    func consumePendingWatcherInvite() -> ParsedWatcherInviteLink? {
        let value = pendingWatcherInvite
        pendingWatcherInvite = nil
        return value
    }

    func openLiveSessionFromNotification(sessionId: String, shareUrl: String?) {
        let cleanId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        TelemetryManager.shared.trackWatcherPushOpened()
        pendingOpenSessionId = cleanId
        pendingOpenShareURL = shareUrl
    }

    func consumePendingOpenSession() -> (sessionId: String, shareUrl: String?)? {
        guard let id = pendingOpenSessionId else { return nil }
        let url = pendingOpenShareURL
        pendingOpenSessionId = nil
        pendingOpenShareURL = nil
        return (id, url)
    }

    // MARK: - HTTP Helpers

    private func fetchIdToken(user: FirebaseAuth.User, forceRefresh: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "TrustedWatchers",
                        code: 401,
                        userInfo: [NSLocalizedDescriptionKey: "Missing authentication token"]
                    ))
                }
            }
        }
    }

    private func postAuthenticated(url: URL, user: FirebaseAuth.User, body: [String: Any]) async throws -> (Int, Data) {
        var token = try await fetchIdToken(user: user, forceRefresh: false)
        var (status, data) = try await executePost(url: url, token: token, body: body)
        if status == 401 {
            token = try await fetchIdToken(user: user, forceRefresh: true)
            (status, data) = try await executePost(url: url, token: token, body: body)
        }
        return (status, data)
    }

    private func executePost(url: URL, token: String, body: [String: Any]) async throws -> (Int, Data) {
        var request = LiveSharingManager.makeLiveShareRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    private func getAuthenticated(url: URL, token: String) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    // MARK: - Pure Parsers (unit tested)

    static func parseWatcherInviteLink(_ url: URL) -> ParsedWatcherInviteLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let segments = url.pathComponents.filter { $0 != "/" }

        let isWebWatcherPath = (scheme == "https" || scheme == "http") &&
            (host == "trackme.shvms.in" || host == "www.trackme.shvms.in") &&
            segments.count >= 2 &&
            segments[0].lowercased() == "live" &&
            segments[1].lowercased() == "watcher"

        let isCustomWatcherPath = scheme == "trackme" &&
            ((host == "live" && segments.first?.lowercased() == "watcher") ||
             (host == "watcher"))

        guard isWebWatcherPath || isCustomWatcherPath else { return nil }
        guard let uid = components.queryItems?.first(where: { $0.name == "inviterUid" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            return nil
        }
        let name = components.queryItems?.first(where: { $0.name == "inviterName" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedWatcherInviteLink(
            inviterUid: uid,
            inviterName: name?.isEmpty == false ? name : nil
        )
    }

    static func parseInboxInvite(from data: Data, now: Date = Date()) -> WatcherInboxInvite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let invite = root["invite"] as? [String: Any],
              let sessionId = (invite["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        let rawRider = (invite["riderName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let riderName = (rawRider?.isEmpty == false ? rawRider : nil) ?? "TrackMe Rider"
        let rawShareUrl = (invite["shareUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shareUrl = (rawShareUrl?.isEmpty == false ? rawShareUrl : nil) ?? "\(APIConfig.baseURL)/live/\(sessionId)"

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        func parseDate(_ value: Any?) -> Date? {
            guard let str = value as? String, !str.isEmpty else { return nil }
            return isoWithFraction.date(from: str) ?? isoBasic.date(from: str)
        }

        let startedAt = parseDate(invite["startedAt"])
        let expiresAt = parseDate(invite["expiresAt"])
        if let expiresAt, now > expiresAt {
            return nil
        }
        return WatcherInboxInvite(
            sessionId: sessionId,
            shareUrl: shareUrl,
            riderName: riderName,
            startedAt: startedAt,
            expiresAt: expiresAt
        )
    }
}

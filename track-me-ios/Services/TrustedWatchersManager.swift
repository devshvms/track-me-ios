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
    let code: String
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

    func createWatcherInviteLink() async -> Result<String, Error> {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            return .failure(NSError(domain: "TrustedWatchers", code: 401, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Sign in to share your live location.")
            ]))
        }
        guard let url = URL(string: APIConfig.LiveShare.startSession) else {
            return .failure(NSError(domain: "TrustedWatchers", code: 0))
        }

        var body: [String: Any] = ["action": "create_watcher_invite"]
        if let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            body["inviterName"] = displayName
        }

        do {
            let (status, data) = try await postAuthenticated(url: url, user: user, body: body)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if status == 200 {
                if let inviteUrl = (json["inviteUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !inviteUrl.isEmpty {
                    return .success(inviteUrl)
                }
                if let code = (json["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   Self.isValidInviteCode(code) {
                    return .success(APIConfig.LiveShare.watcherInviteLink(code: code, inviterName: user.displayName))
                }
            }
            let serverError = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(NSError(domain: "TrustedWatchers", code: status, userInfo: [
                NSLocalizedDescriptionKey: (serverError?.isEmpty == false ? serverError : nil)
                    ?? LocalizationHelper.localized("Could not create watcher invite.")
            ]))
        } catch {
            return .failure(error)
        }
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

    func acceptWatcherInvite(code: String, inviterName: String?) async -> Result<Void, Error> {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            return .failure(NSError(domain: "TrustedWatchers", code: 401, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Sign in to accept this Trusted Watcher invite.")
            ]))
        }
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidInviteCode(cleanCode) else {
            return .failure(NSError(domain: "TrustedWatchers", code: 400, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Invalid watcher invite.")
            ]))
        }
        guard let url = URL(string: APIConfig.LiveShare.startSession) else {
            return .failure(NSError(domain: "TrustedWatchers", code: 0))
        }

        var body: [String: Any] = [
            "action": "accept_watcher",
            "code": cleanCode,
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
            let rawServerError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let serverError = rawServerError?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let serverError, !serverError.isEmpty {
                return .failure(NSError(domain: "TrustedWatchers", code: status, userInfo: [
                    NSLocalizedDescriptionKey: serverError
                ]))
            }
            if status == 409 {
                return .failure(NSError(domain: "TrustedWatchers", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: LocalizationHelper.localized("This rider already has 5 trusted watchers.")
                ]))
            }
            if status == 404 {
                return .failure(NSError(domain: "TrustedWatchers", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: LocalizationHelper.localized("This watcher invite has expired or already been used.")
                ]))
            }
            return .failure(NSError(domain: "TrustedWatchers", code: status, userInfo: [
                NSLocalizedDescriptionKey: LocalizationHelper.localized("Could not accept watcher invite.")
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
        openLiveSession(sessionId: sessionId, shareUrl: shareUrl, trackPush: true)
    }

    func openLiveSession(sessionId: String, shareUrl: String? = nil, trackPush: Bool = false) {
        let cleanId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        if trackPush {
            TelemetryManager.shared.trackWatcherPushOpened()
        }
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

    private static let inviteCodeRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{12,128}$")

    static func isValidInviteCode(_ code: String) -> Bool {
        let range = NSRange(location: 0, length: code.utf16.count)
        return inviteCodeRegex.firstMatch(in: code, range: range) != nil
    }

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
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              isValidInviteCode(code) else {
            return nil
        }
        let name = components.queryItems?.first(where: { $0.name == "inviterName" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedWatcherInviteLink(
            code: code,
            inviterName: name?.isEmpty == false ? name : nil
        )
    }

    static func parseInboxInvite(from data: Data, now: Date = Date()) -> WatcherInboxInvite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let invite = (root["activeInvite"] as? [String: Any]) ?? (root["invite"] as? [String: Any]),
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

        func parseEpoch(_ raw: Double) -> Date? {
            guard raw.isFinite, raw > 0 else { return nil }
            let seconds = raw >= 1_000_000_000_000 ? raw / 1_000.0 : raw
            return Date(timeIntervalSince1970: seconds)
        }

        func parseDate(_ value: Any?) -> Date? {
            if let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                return parseEpoch(num.doubleValue)
            }
            if let str = value as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if let raw = Double(trimmed), let parsed = parseEpoch(raw) {
                    return parsed
                }
                return isoWithFraction.date(from: trimmed) ?? isoBasic.date(from: trimmed)
            }
            return nil
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

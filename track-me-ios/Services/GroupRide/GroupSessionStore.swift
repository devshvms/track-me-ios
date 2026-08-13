import Foundation
import Security

final class GroupSessionStore {
    static let shared = GroupSessionStore()

    nonisolated enum StatusOperation: String, Codable, Equatable {
        case set
        case clear
    }

    nonisolated struct StoredStatus: Codable, Equatable {
        let raw: String
        let envelope: String?
        let setAtElapsedMillis: Int64?
        let bootEpochAtSetMillis: Int64?
        let pendingOperation: StatusOperation?
        let acknowledged: Bool
    }

    nonisolated struct Record: Codable, Equatable {
        let groupId: String
        let joinCode: String
        let isLeader: Bool
        var expiresAtMillis: Int64
        let maxMembers: Int
        var rev: Int
        var hasStarted: Bool
        var status: StoredStatus?
        var alertsMuted: Bool
        /// uid -> exact alert status raw value for which this device actually interrupted.
        /// This is session-scoped and contains no display name or location.
        var shownAlertStatuses: [String: String]

        init(
            groupId: String,
            joinCode: String,
            isLeader: Bool,
            expiresAtMillis: Int64,
            maxMembers: Int,
            rev: Int,
            hasStarted: Bool = false,
            status: StoredStatus? = nil,
            alertsMuted: Bool = false,
            shownAlertStatuses: [String: String] = [:]
        ) {
            self.groupId = groupId
            self.joinCode = joinCode
            self.isLeader = isLeader
            self.expiresAtMillis = expiresAtMillis
            self.maxMembers = maxMembers
            self.rev = rev
            self.hasStarted = hasStarted
            self.status = status
            self.alertsMuted = alertsMuted
            self.shownAlertStatuses = shownAlertStatuses
        }

        private enum CodingKeys: String, CodingKey {
            case groupId, joinCode, isLeader, expiresAtMillis, maxMembers, rev, hasStarted
            case status, alertsMuted, shownAlertStatuses
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            groupId = try values.decode(String.self, forKey: .groupId)
            joinCode = try values.decode(String.self, forKey: .joinCode)
            isLeader = try values.decode(Bool.self, forKey: .isLeader)
            expiresAtMillis = try values.decode(Int64.self, forKey: .expiresAtMillis)
            maxMembers = try values.decode(Int.self, forKey: .maxMembers)
            rev = try values.decode(Int.self, forKey: .rev)
            hasStarted = try values.decodeIfPresent(Bool.self, forKey: .hasStarted) ?? false
            status = try values.decodeIfPresent(StoredStatus.self, forKey: .status)
            alertsMuted = try values.decodeIfPresent(Bool.self, forKey: .alertsMuted) ?? false
            shownAlertStatuses = try values.decodeIfPresent([String: String].self, forKey: .shownAlertStatuses) ?? [:]
        }
    }

    private let defaults: UserDefaults
    private let recordKey = "groupRide.sessionRecord.v1"
    private let tokenAccount = "groupRide.inviteToken.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(record: Record, token: String) throws {
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: recordKey)
        defaults.synchronize()
        try saveToken(token)
    }

    func load(now: Date = Date()) -> (record: Record, token: String)? {
        guard let data = defaults.data(forKey: recordKey),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let token = loadToken() else {
            clear()
            return nil
        }
        let expiry = Date(timeIntervalSince1970: TimeInterval(record.expiresAtMillis) / 1000)
        guard expiry > now else {
            clear()
            return nil
        }
        return (record, token)
    }

    func updateRev(_ rev: Int) {
        updateRecord { $0.rev = rev }
    }

    func updateLifecycle(expiresAtMillis: Int64, hasStarted: Bool, rev: Int? = nil) {
        updateRecord {
            $0.expiresAtMillis = expiresAtMillis
            $0.hasStarted = hasStarted
            if let rev { $0.rev = rev }
        }
    }

    func updateStatus(_ status: StoredStatus?) {
        updateRecord { $0.status = status }
    }

    func updateAlertsMuted(_ muted: Bool) {
        updateRecord { $0.alertsMuted = muted }
    }

    func updateShownAlertStatus(_ raw: String?, for uid: String) {
        updateRecord { record in
            if let raw {
                record.shownAlertStatuses[uid] = raw
            } else {
                record.shownAlertStatuses.removeValue(forKey: uid)
            }
        }
    }

    func clear() {
        defaults.removeObject(forKey: recordKey)
        defaults.synchronize()
        deleteToken()
    }

    private func saveToken(_ token: String) throws {
        deleteToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "in.shvms.track-me-ios",
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    private func updateRecord(_ mutation: (inout Record) -> Void) {
        guard let data = defaults.data(forKey: recordKey),
              var record = try? JSONDecoder().decode(Record.self, from: data) else { return }
        mutation(&record)
        guard let updated = try? JSONEncoder().encode(record) else { return }
        defaults.set(updated, forKey: recordKey)
    }

    private func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "in.shvms.track-me-ios",
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "in.shvms.track-me-ios",
            kSecAttrAccount as String: tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct KeychainError: Swift.Error, Equatable {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
    }
}

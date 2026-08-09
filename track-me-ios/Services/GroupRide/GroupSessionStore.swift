import Foundation
import Security

final class GroupSessionStore {
    static let shared = GroupSessionStore()

    struct Record: Codable, Equatable {
        let groupId: String
        let joinCode: String
        let isLeader: Bool
        let expiresAtMillis: Int64
        let maxMembers: Int
        let rev: Int
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
        guard let data = defaults.data(forKey: recordKey),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              let token = loadToken() else { return }
        record = Record(
            groupId: record.groupId,
            joinCode: record.joinCode,
            isLeader: record.isLeader,
            expiresAtMillis: record.expiresAtMillis,
            maxMembers: record.maxMembers,
            rev: rev
        )
        try? save(record: record, token: token)
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

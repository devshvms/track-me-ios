import CryptoKit
import Foundation
import Security

enum GroupCrypto {
    static let envelopeVersion = "v1"
    static let hkdfInfo = "trackme:group:v1"
    static let hkdfCodeInfo = "trackme:group-code:v1"
    static let tokenBytes = 16
    static let keyLengthBytes = 32
    static let nonceLengthBytes = 12
    static let tagLengthBytes = 16
    static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let joinCodeLength = 6

    enum Purpose: Equatable {
        case meta
        case code
        case roster(uid: String)
        case position(uid: String)

        var context: String {
            switch self {
            case .meta:
                return "\(GroupCrypto.envelopeVersion):meta"
            case .code:
                return "\(GroupCrypto.envelopeVersion):code"
            case .roster(let uid):
                return "\(GroupCrypto.envelopeVersion):roster:\(uid)"
            case .position(let uid):
                return "\(GroupCrypto.envelopeVersion):pos:\(uid)"
            }
        }
    }

    enum Error: Swift.Error, Equatable {
        case invalidToken
        case invalidJoinCode
        case invalidKey
        case malformedEnvelope
        case authenticationFailed
        case randomFailure
    }

    static func generateInviteToken() throws -> String {
        try base64UrlEncode(randomBytes(count: tokenBytes))
    }

    static func groupTokenHash(_ token: String) throws -> String {
        try requireToken(token)
        let digest = SHA256.hash(data: Data(token.utf8))
        return Data(digest).hexString
    }

    static func generateJoinCode() throws -> String {
        let limit = 256 - (256 % crockfordAlphabet.count)
        var output = ""
        while output.count < joinCodeLength {
            for byte in try randomBytes(count: joinCodeLength) {
                let value = Int(byte)
                guard value < limit else { continue }
                output.append(crockfordAlphabet[value % crockfordAlphabet.count])
                if output.count == joinCodeLength { break }
            }
        }
        return output
    }

    static func normalizeJoinCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
            .map { char -> Character in
                if char == "I" || char == "L" { return "1" }
                if char == "O" { return "0" }
                return char
            }
        let normalized = String(cleaned)
        guard normalized.count == joinCodeLength else { return nil }
        guard normalized.allSatisfy({ crockfordAlphabet.contains($0) }) else { return nil }
        return normalized
    }

    static func deriveGroupKey(token: String) throws -> SymmetricKey {
        try requireToken(token)
        return hkdf(ikm: Data(token.utf8), info: Data(hkdfInfo.utf8), length: keyLengthBytes)
    }

    static func deriveCodeKey(joinCode: String) throws -> SymmetricKey {
        guard normalizeJoinCode(joinCode) == joinCode else { throw Error.invalidJoinCode }
        return hkdf(ikm: Data(joinCode.utf8), info: Data(hkdfCodeInfo.utf8), length: keyLengthBytes)
    }

    static func hkdf(ikm: Data, info: Data, length: Int, salt: Data = Data()) -> SymmetricKey {
        let material = SymmetricKey(data: ikm)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return derived
    }

    static func seal(
        key: SymmetricKey,
        plaintext: String,
        purpose: Purpose,
        nonce: Data? = nil
    ) throws -> String {
        try requireKey(key)
        let nonceData = try nonce ?? randomBytes(count: nonceLengthBytes)
        guard nonceData.count == nonceLengthBytes,
              let aesNonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw Error.malformedEnvelope
        }
        let box = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: key,
            nonce: aesNonce,
            authenticating: Data(purpose.context.utf8)
        )
        let body = box.ciphertext + box.tag
        return "\(envelopeVersion).\(base64UrlEncode(nonceData)).\(base64UrlEncode(body))"
    }

    static func open(key: SymmetricKey, envelope: String, purpose: Purpose) throws -> String {
        try requireKey(key)
        let parts = envelope.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == envelopeVersion else { throw Error.malformedEnvelope }
        guard let nonceData = base64UrlDecode(parts[1]),
              let body = base64UrlDecode(parts[2]),
              nonceData.count == nonceLengthBytes,
              body.count >= tagLengthBytes,
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw Error.malformedEnvelope
        }

        let ciphertext = Data(body.prefix(body.count - tagLengthBytes))
        let tag = Data(body.suffix(tagLengthBytes))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            let data = try AES.GCM.open(box, using: key, authenticating: Data(purpose.context.utf8))
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw Error.authenticationFailed
        }
    }

    static func wrapTokenForCode(joinCode: String, token: String, nonce: Data? = nil) throws -> String {
        try requireToken(token)
        return try seal(key: deriveCodeKey(joinCode: joinCode), plaintext: token, purpose: .code, nonce: nonce)
    }

    static func unwrapTokenWithCode(joinCode: String, wrapped: String) throws -> String {
        let token = try open(key: deriveCodeKey(joinCode: joinCode), envelope: wrapped, purpose: .code)
        try requireToken(token)
        return token
    }

    static func base64UrlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64UrlDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard result == errSecSuccess else { throw Error.randomFailure }
        return Data(bytes)
    }

    private static func requireToken(_ token: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard token.count == 22,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw Error.invalidToken
        }
    }

    private static func requireKey(_ key: SymmetricKey) throws {
        guard key.data.count == keyLengthBytes else { throw Error.invalidKey }
    }
}

extension SymmetricKey {
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

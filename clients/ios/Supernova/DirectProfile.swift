import Foundation
import Security
import CryptoKit

struct DirectProfile {
    private let key: P256.Signing.PrivateKey
    private static let service = "am.supernova.local.direct-profile"

    init() {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: "p256"]
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let bytes = result as? Data, let stored = try? P256.Signing.PrivateKey(rawRepresentation: bytes) {
            key = stored
            return
        }
        let fresh = P256.Signing.PrivateKey()
        var record = item
        record[kSecValueData as String] = fresh.rawRepresentation
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(record as CFDictionary, nil)
        key = fresh
    }

    func payload(role: String, token: String, name: String) throws -> [String: Any] {
        let signature = try key.signature(for: Self.transcript(role, token, name))
        return ["v": 1, "name": name,
                "key": key.publicKey.derRepresentation.base64EncodedString(),
                "signature": signature.derRepresentation.base64EncodedString()]
    }

    static func verify(_ data: [String: Any], role: String, token: String) throws -> DirectContact {
        guard let name = data["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
              let encodedKey = data["key"] as? String, encodedKey.utf8.count <= 160,
              let bytes = Data(base64Encoded: encodedKey),
              let key = try? P256.Signing.PublicKey(derRepresentation: bytes),
              let encodedSignature = data["signature"] as? String, encodedSignature.utf8.count <= 112,
              let der = Data(base64Encoded: encodedSignature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: transcript(role, token, name)) else {
            throw DirectError("Подпись профиля не прошла проверку")
        }
        return DirectContact(id: DirectIdentity.digest(key.derRepresentation), name: name)
    }

    private static func transcript(_ role: String, _ token: String, _ name: String) -> Data {
        Data("betelgeuse-direct-v1\n\(role)\n\(token)\n\(name)".utf8)
    }
}

import Foundation
import CryptoKit
import Security

enum Keychain {
    private static let service = "am.supernova.app"
    private static let fallbackKey = "supernova.dh.fallback.v1"

    static func loadOrCreatePrivateKey(account: String) -> Curve25519.KeyAgreement.PrivateKey {
        if let data = read(account: account),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        if let stored = UserDefaults.standard.string(forKey: fallbackKey),
           let data = Data(base64Encoded: stored),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            _ = write(account: account, data: data)
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        if !write(account: account, data: key.rawRepresentation) {
            // Unsigned/simulator builds lack the keychain entitlement. Keep the
            // local demo identity stable; a signed build uses Keychain normally.
            UserDefaults.standard.set(key.rawRepresentation.base64EncodedString(), forKey: fallbackKey)
        }
        return key
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    private static func write(account: String, data: Data) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

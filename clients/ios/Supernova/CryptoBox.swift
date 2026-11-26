import Foundation
import CryptoKit

enum LocalCrypto {
    static let salt = Data("Supernova-Local-Salt-v1".utf8)
    static let info = Data("Supernova-Local-Messages-v1".utf8)
    static let aadPrefix = "Supernova-Local-AEAD-v1"

    static func messageKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicRaw: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicRaw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }

    static func aad(from: String, to: String, id: String, ts: Int64) -> Data {
        Data("\(aadPrefix)\0\(from)\0\(to)\0\(id)\0\(ts)".utf8)
    }

    static func seal(text: String, key: SymmetricKey, from: String, to: String, id: String, ts: Int64) throws -> Data {
        let aad = aad(from: from, to: to, id: id, ts: ts)
        let box = try ChaChaPoly.seal(Data(text.utf8), using: key, authenticating: aad)
        return box.combined
    }

    static func open(combined: Data, key: SymmetricKey, from: String, to: String, id: String, ts: Int64) throws -> String {
        let aad = aad(from: from, to: to, id: id, ts: ts)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plain = try ChaChaPoly.open(box, using: key, authenticating: aad)
        guard let text = String(data: plain, encoding: .utf8) else { throw CryptoError.invalidUTF8 }
        return text
    }

    static func fingerprint(keys: [Data]) -> String {
        let sorted = keys.map { $0.base64EncodedString() }.sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(sorted.utf8))
        return digest.prefix(8).map { String(format: "%02X", Int($0)) }.joined(separator: " ")
    }

    enum CryptoError: Error { case invalidUTF8 }
}

import Foundation
import Security
import CryptoKit

struct DirectIdentity {
    let identity: SecIdentity
    let fingerprint: String

    init() throws {
        let signingKey = P256.Signing.PrivateKey()
        let point = signingKey.publicKey.x963Representation
        let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                          kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                          kSecAttrKeySizeInBits as String: 256] as [String: Any]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(signingKey.x963Representation as CFData, attributes as CFDictionary, &error) else {
            throw DirectError("Не удалось импортировать ключ TLS")
        }
        let ecdsaSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        let ecKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        let prime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let algorithm = Self.der(0x30, ecdsaSHA256)
        let name = Self.der(0x30, Self.der(0x31, Self.der(0x30,
            Data([0x06, 0x03, 0x55, 0x04, 0x03]) + Self.der(0x0C, Data("Supernova Direct".utf8)))))
        let dates = Self.der(0x30, Self.der(0x17, Data("200101000000Z".utf8)) +
            Self.der(0x17, Data("491231235959Z".utf8)))
        let spki = Self.der(0x30, Self.der(0x30, ecKey + prime256v1) + Self.der(0x03, Data([0]) + point))
        let serial = try Self.random(16)
        let body = Self.der(0x30, Self.der(0xA0, Self.der(0x02, Data([2]))) +
            Self.der(0x02, Data([1]) + serial) + algorithm + name + dates + name + spki)
        let signature = try signingKey.signature(for: body).derRepresentation
        let certificateData = Self.der(0x30, body + algorithm + Self.der(0x03, Data([0]) + signature))
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw DirectError("Не удалось создать сертификат TLS")
        }
        self.identity = identity
        fingerprint = Self.digest(certificateData)
    }

    static func random(_ length: Int) throws -> Data {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw DirectError("Недоступен генератор случайных чисел") }
        return data
    }

    static func digest(_ bytes: Data) -> String { hex(SHA256.hash(data: bytes)) }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func der(_ tag: UInt8, _ value: Data) -> Data {
        if value.count < 128 { return Data([tag, UInt8(value.count)]) + value }
        if value.count < 256 { return Data([tag, 0x81, UInt8(value.count)]) + value }
        return Data([tag, 0x82, UInt8(value.count >> 8), UInt8(value.count & 255)]) + value
    }
}

struct DirectError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

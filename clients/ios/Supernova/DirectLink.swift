import Foundation
import Network
import Security

enum DirectPacket: UInt8 {
    case hello = 1, welcome, text, offer, accept, decline, chunk, done, received
    case call = 10, answer, hangup, audio, keepalive
}

final class DirectLink {
    static let maxBody = 65_536
    static let tlsQueue = DispatchQueue(label: "supernova.tls")
    let connection: NWConnection
    private var buffer = Data()
    var onReady: (() -> Void)?
    var onClosed: ((String) -> Void)?
    var onPacket: ((DirectPacket, Data) throws -> Void)?
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    static func parameters(identity: SecIdentity? = nil, pin: String? = nil) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        if let identity {
            guard let local = sec_identity_create(identity) else { throw DirectError("Недоступен сертификат TLS") }
            sec_protocol_options_set_local_identity(options, local)
        }
        if let pin {
            sec_protocol_options_set_verify_block(options, { _, trust, done in
                let certificates = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
                let actual = certificates?.first.map { DirectIdentity.digest(SecCertificateCopyData($0) as Data) }
                done(actual == pin)
            }, tlsQueue)
        }
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close("Соединение закрыто")
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ type: DirectPacket, _ payload: Data = Data(), completed: ((Bool) -> Void)? = nil) {
        guard !closed, payload.count <= Self.maxBody else { completed?(false); return }
        let length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: length) { Data($0) }
        connection.send(content: Data([type.rawValue]) + header + payload, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error.localizedDescription) }
            completed?(error == nil)
        })
    }

    func sendJSON(_ type: DirectPacket, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        send(type, data)
    }

    func close(_ reason: String = "Соединение закрыто") {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxBody) { [weak self] data, _, end, error in
            guard let self, !self.closed else { return }
            do {
                if let data { try self.consume(data) }
                if let error { self.close(error.localizedDescription) }
                else if end { self.close("Собеседник отключился") }
                else { self.receive() }
            } catch {
                self.close(error.localizedDescription)
            }
        }
    }

    private func consume(_ data: Data) throws {
        buffer.append(data)
        while buffer.count >= 5 {
            let header = Array(buffer.prefix(5))
            let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxBody, let type = DirectPacket(rawValue: header[0]) else {
                throw DirectError("Несовместимый сетевой пакет")
            }
            guard buffer.count >= 5 + length else { return }
            let body = Data(buffer.dropFirst(5).prefix(length))
            buffer.removeFirst(5 + length)
            try onPacket?(type, body)
            if closed { return }
        }
    }

    static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var entry: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = entry {
            let item = current.pointee
            entry = item.ifa_next
            guard let socket = item.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.ifa_name) == "en0", (item.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

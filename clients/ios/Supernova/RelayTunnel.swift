import Foundation
import Network

struct RelayAddress {
    let host: String
    let port: NWEndpoint.Port

    var authority: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return "\(address):\(port.rawValue)"
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 262, let parts = URLComponents(string: "betelgeuse-relay://\(value)"),
              parts.path.isEmpty, let address = route(parts) else { return nil }
        return address
    }

    static func route(_ parts: URLComponents) -> Self? {
        guard parts.scheme == "betelgeuse-relay", let raw = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let number = parts.port, (1...65535).contains(number),
              let port = NWEndpoint.Port(rawValue: UInt16(number)) else { return nil }
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        guard !host.isEmpty, host.utf8.count <= 253,
              IPv6Address(host) != nil || host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return Self(host: host, port: port)
    }
}

/// Adds a routing preface to raw TCP, then copies bytes between the relay and
/// a loopback TLS endpoint. The relay never gets the application invitation secret.
final class RelayTunnel {
    private static let loopback = NWEndpoint.Host.ipv4(IPv4Address("127.0.0.1")!)
    private let remote: NWConnection
    private let role: String
    private let slot: String
    private var local: NWConnection?
    private var listener: NWListener?
    private var timer: DispatchWorkItem?
    private var stopped = false
    var waiting: (() -> Void)?
    var paired: (() -> Void)?
    var failed: ((String) -> Void)?

    init(address: RelayAddress, slot: String, host: Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        remote = NWConnection(host: NWEndpoint.Host(address.host), port: address.port, using: NWParameters(tls: nil, tcp: tcp))
        role = host ? "H" : "G"
        self.slot = slot
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.fail("Ретранслятор не ответил. Проверьте адрес и порт.") }
        timer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: timeout)
        remote.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                let header = Data("BGL1 \(self.role) \(self.slot)\n".utf8)
                self.remote.send(content: header, completion: .contentProcessed { [weak self] error in
                    if let error { self?.fail(error.localizedDescription) }
                    else { self?.readSignal() }
                })
            case .failed(let error): self.fail(error.localizedDescription)
            default: break
            }
        }
        remote.start(queue: .main)
    }

    private func readSignal() {
        guard !stopped else { return }
        remote.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            self.timer?.cancel()
            self.timer = nil
            switch data?.first {
            case 87 where self.role == "H": // W: invitation reserved.
                self.waiting?()
                self.readSignal()
            case 75: self.paired?() // K: begin end-to-end TLS.
            case 69: self.fail("Приглашение недоступно или срок его действия истёк")
            default: self.fail(error?.localizedDescription ?? "Ретранслятор закрыл соединение")
            }
        }
    }

    func connectLoopback(_ port: NWEndpoint.Port) {
        use(NWConnection(host: Self.loopback, port: port, using: .tcp))
    }

    func openLoopback(ready: @escaping (NWEndpoint.Port) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: Self.loopback, port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                if let port = listener.port { ready(port) }
            case .failed(let error): self.fail(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.local == nil else { connection.cancel(); return }
            self.listener?.cancel()
            self.listener = nil
            self.use(connection)
        }
        listener.start(queue: .main)
    }

    private func use(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        local = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.stopped else { return }
            switch state {
            case .ready:
                self.copy(self.remote, to: connection)
                self.copy(connection, to: self.remote)
            case .failed(let error): self.fail(error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func copy(_ from: NWConnection, to: NWConnection) {
        guard !stopped else { return }
        from.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, end, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if let failure = sendError ?? error { self?.fail(failure.localizedDescription) }
                    else if end { self?.fail("Интернет-соединение завершено") }
                    else { self?.copy(from, to: to) }
                })
            } else if let error { self.fail(error.localizedDescription) }
            else if end { self.fail("Интернет-соединение завершено") }
            else { self.copy(from, to: to) }
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        close()
        failed?(message)
    }

    func close() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        listener?.cancel()
        local?.cancel()
        remote.cancel()
    }
}

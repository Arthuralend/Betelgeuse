import Foundation
import Network
import CryptoKit
import UIKit

struct DirectMessage: Identifiable, Codable {
    var id = UUID()
    let text: String
    let mine: Bool
}

struct DirectContact: Identifiable, Codable {
    let id: String
    let name: String
}

private struct DirectHistory: Codable {
    var contacts: [DirectContact] = []
    var messages: [String: [DirectMessage]] = [:]
}

struct DirectOffer: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
}

final class DirectSession: ObservableObject {
    static let maxFile: Int64 = 1_073_741_824
    private static let version = 1

    @Published var relayAddress = UserDefaults.standard.string(forKey: "direct.relay") ?? ""
    @Published var name = UserDefaults.standard.string(forKey: "direct.name") ?? "iPhone"
    @Published private(set) var status = "Готово к подключению"
    @Published private(set) var invite: String?
    @Published private(set) var peer: DirectContact?
    @Published private(set) var messages: [DirectMessage] = []
    @Published private(set) var contacts: [DirectContact] = []
    @Published private(set) var incoming: DirectOffer?
    @Published private(set) var fileURL: URL?
    @Published private(set) var transfer: String?
    @Published private(set) var call: CallPhase?
    @Published private(set) var busy = false

    private var history = DirectHistory()
    private var selectedHistory: String?
    private var listener: NWListener?
    private var relayTunnel: RelayTunnel?
    private var link: DirectLink?
    private var audio: CallAudio?
    private var pendingAudio = 0
    private var outgoing: (url: URL, name: String, size: Int64)?
    private var receiving: IncomingFile?
    private var waitingForReceipt = false
    private let profile = DirectProfile()
    private let storage = URL.documentsDirectory.appendingPathComponent("direct-history.json")

    init() {
        if let data = try? Data(contentsOf: storage),
           let saved = try? JSONDecoder().decode(DirectHistory.self, from: data) {
            history = saved
            contacts = saved.contacts
        }
    }

    func saveName() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if name.isEmpty { name = "iPhone" }
        UserDefaults.standard.set(name, forKey: "direct.name")
    }

    func hostInternet() {
        guard let relay = RelayAddress.parse(relayAddress) else {
            status = "Укажите адрес и порт ретранслятора"
            return
        }
        relayAddress = relay.authority
        UserDefaults.standard.set(relay.authority, forKey: "direct.relay")
        host(relay: relay)
    }

    func host(relay: RelayAddress? = nil) {
        guard !busy else { return }
        let ip = relay == nil ? DirectLink.localIPv4() : "127.0.0.1"
        guard let ip, let address = IPv4Address(ip) else {
            status = "Подключитесь к Wi-Fi и попробуйте снова"
            return
        }
        saveName()
        do {
            let identity = try DirectIdentity()
            let token = DirectIdentity.hex(try DirectIdentity.random(32))
            let slot = relay == nil ? nil : DirectIdentity.hex(try DirectIdentity.random(32))
            let parameters = try DirectLink.parameters(identity: identity.identity)
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            busy = true
            status = "Создаю приглашение…"
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    if let relay, let slot {
                        self.reserveRelay(relay, port: port, slot: slot, pin: identity.fingerprint, token: token)
                    } else {
                        self.invite = "betelgeuse://\(ip):\(port.rawValue)/\(identity.fingerprint)/\(token)"
                        self.status = "Передайте приглашение собеседнику"
                    }
                case .failed(let error):
                    self.relayFailed(error.localizedDescription)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.link == nil else { connection.cancel(); return }
                self.attach(DirectLink(connection), token: token, host: true, relayed: relay != nil)
            }
            listener.start(queue: .main)
        } catch {
            status = error.localizedDescription
        }
    }

    func join(_ input: String) {
        guard !busy else { return }
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("betelgeuse-relay://") {
            joinInternet(clean)
            return
        }
        guard let parts = URLComponents(string: clean), parts.scheme == "betelgeuse",
              let host = parts.host, IPv4Address(host) != nil,
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            status = "Вставьте ссылку-приглашение Betelgeuse"
            return
        }
        let fields = parts.path.split(separator: "/").map(String.init)
        guard fields.count == 2, fields.allSatisfy(Self.isHexDigest),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            status = "Ссылка-приглашение повреждена"
            return
        }
        saveName()
        do {
            let parameters = try DirectLink.parameters(pin: fields[0])
            let conn = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
            attach(DirectLink(conn), token: fields[1], host: false)
        } catch {
            status = error.localizedDescription
        }
    }

    private func reserveRelay(_ address: RelayAddress, port: NWEndpoint.Port, slot: String, pin: String, token: String) {
        let tunnel = installTunnel(address, slot: slot, host: true)
        tunnel.waiting = { [weak self] in
            self?.invite = "betelgeuse-relay://\(address.authority)/\(slot)/\(pin)/\(token)"
            self?.status = "Передайте интернет-приглашение собеседнику"
        }
        tunnel.paired = { [weak self, weak tunnel] in
            self?.invite = nil
            self?.status = "Устанавливаю защищённое соединение…"
            tunnel?.connectLoopback(port)
        }
        tunnel.start()
    }

    private func joinInternet(_ input: String) {
        guard input.utf8.count <= 512, let parts = URLComponents(string: input),
              let address = RelayAddress.route(parts) else {
            status = "Ссылка-приглашение повреждена"
            return
        }
        let fields = parts.path.split(separator: "/").map(String.init)
        guard fields.count == 3, fields.allSatisfy(Self.isHexDigest) else {
            status = "Ссылка-приглашение повреждена"
            return
        }
        saveName()
        let tunnel = installTunnel(address, slot: fields[0], host: false)
        tunnel.paired = { [weak self, weak tunnel] in
            guard let self, let tunnel else { return }
            do {
                let parameters = try DirectLink.parameters(pin: fields[1])
                try tunnel.openLoopback { [weak self] port in
                    guard let self else { return }
                    let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
                    self.attach(DirectLink(connection), token: fields[2], host: false, relayed: true)
                }
            } catch {
                self.relayFailed(error.localizedDescription)
            }
        }
        tunnel.start()
    }

    private func installTunnel(_ address: RelayAddress, slot: String, host: Bool) -> RelayTunnel {
        let tunnel = RelayTunnel(address: address, slot: slot, host: host)
        relayTunnel = tunnel
        busy = true
        status = "Подключаюсь к ретранслятору…"
        tunnel.failed = { [weak self, weak tunnel] reason in
            guard let self, self.relayTunnel === tunnel else { return }
            self.relayFailed(reason)
        }
        return tunnel
    }

    private func relayFailed(_ reason: String) {
        stopRelay()
        stopListening()
        link?.close(reason)
        status = reason
    }

    private func stopRelay() {
        let tunnel = relayTunnel
        relayTunnel = nil
        tunnel?.close()
    }

    private func scheduleKeepalive(_ connection: DirectLink) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self, weak connection] in
            guard let self, let connection, self.link === connection, self.peer != nil else { return }
            connection.send(.keepalive)
            self.scheduleKeepalive(connection)
        }
    }

    func disconnect() {
        stopRelay()
        stopListening()
        link?.close()
        status = "Готово к подключению"
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        invite = nil
        busy = link != nil
    }

    private func attach(_ connection: DirectLink, token: String, host: Bool, relayed: Bool = false) {
        link = connection
        busy = true
        status = "Устанавливаю защищённое соединение…"
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection, !host else { return }
            do {
                var payload = try self.profile.payload(role: "guest", token: token, name: self.name)
                payload["token"] = token
                connection.sendJSON(.hello, payload)
            } catch { connection.close(error.localizedDescription) }
        }
        connection.onPacket = { [weak self, weak connection] type, payload in
            guard let self, let connection, self.link === connection else { return }
            if self.peer != nil {
                try self.receive(type, payload, link: connection)
                return
            }
            guard type == (host ? .hello : .welcome),
                  let data = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  data["v"] as? Int == Self.version,
                  !host || (data["token"] as? String).map({ Self.sameToken($0, token) }) == true else {
                throw DirectError("Приглашение отклонено")
            }
            let remote = try DirectProfile.verify(data, role: host ? "guest" : "host", token: token)
            if host {
                let payload = try self.profile.payload(role: "host", token: token, name: self.name)
                self.stopListening()
                connection.sendJSON(.welcome, payload)
            }
            self.peer = remote
            self.showHistory(remote.id)
            self.status = relayed ? "Интернет через ретранслятор · TLS 1.3" : "Прямое соединение · TLS 1.3"
            if relayed && host { self.scheduleKeepalive(connection) }
        }
        connection.onClosed = { [weak self, weak connection] reason in
            guard let self, let connection, self.link === connection else { return }
            self.link = nil
            if relayed {
                self.stopRelay()
                self.stopListening()
            }
            self.peer = nil
            let known = Set(self.contacts.map(\.id))
            self.history.messages = self.history.messages.filter { known.contains($0.key) }
            if let id = self.selectedHistory, !known.contains(id) { self.messages = [] }
            self.busy = self.listener != nil
            self.incoming = nil
            self.discardIncoming()
            self.outgoing?.url.stopAccessingSecurityScopedResource()
            self.outgoing = nil
            self.waitingForReceipt = false
            self.transfer = nil
            self.stopCall()
            self.status = reason
        }
        connection.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (relayed ? 20 : 12)) { [weak self, weak connection] in
            guard let self, self.link === connection, self.peer == nil else { return }
            connection?.close("Собеседник не ответил. Проверьте сеть и приглашение.")
        }
    }

    func send(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link, let peer, !text.isEmpty, text.utf8.count <= 8_192 else { return }
        link.send(.text, Data(text.utf8)) { [weak self] success in
            guard success else { return }
            self?.append(DirectMessage(text: text, mine: true), for: peer.id)
        }
    }

    func saveContact() {
        guard let peer else { return }
        history.contacts.removeAll { $0.id == peer.id }
        history.contacts.insert(peer, at: 0)
        history.contacts = Array(history.contacts.prefix(50))
        contacts = history.contacts
        save()
    }

    func removeContact(_ contact: DirectContact) {
        history.contacts.removeAll { $0.id == contact.id }
        history.messages[contact.id] = nil
        contacts = history.contacts
        if selectedHistory == contact.id { messages = [] }
        save()
    }

    func showHistory(_ id: String) {
        selectedHistory = id
        messages = history.messages[id] ?? []
    }

    private func append(_ message: DirectMessage, for id: String) {
        var list = history.messages[id] ?? []
        list.append(message)
        history.messages[id] = Array(list.suffix(100))
        if selectedHistory == id { messages = history.messages[id] ?? [] }
        if contacts.contains(where: { $0.id == id }) { save() }
    }

    private func save() {
        do {
            var persistent = history
            let allowed = Set(persistent.contacts.map(\.id))
            persistent.messages = persistent.messages.filter { allowed.contains($0.key) }
            try JSONEncoder().encode(persistent).write(to: storage, options: [.atomic, .completeFileProtection])
        } catch {
            status = "Не удалось сохранить локальную историю"
        }
    }

    func offerFile(_ url: URL) {
        guard let link, peer != nil, outgoing == nil, receiving == nil, incoming == nil, !waitingForReceipt, call == nil else { return }
        _ = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size >= 0, Int64(size) <= Self.maxFile else {
                throw DirectError("Выберите файл размером до 1 ГБ")
            }
            let name = String(url.lastPathComponent.prefix(90))
            outgoing = (url, name, Int64(size))
            transfer = "Жду согласия на передачу файла"
            link.sendJSON(.offer, ["name": name, "size": size])
        } catch {
            url.stopAccessingSecurityScopedResource()
            status = error.localizedDescription
        }
    }

    func respondToFile(accept: Bool) {
        guard let incoming, let link else { return }
        self.incoming = nil
        guard accept else { link.send(.decline); return }
        do {
            let available = try URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let size = available.volumeAvailableCapacityForImportantUsage, size < incoming.size {
                throw DirectError("На устройстве недостаточно места")
            }
            receiving = try IncomingFile(incoming)
            transfer = "Принимаю \(incoming.name)…"
            link.send(.accept)
        } catch {
            link.send(.decline)
            status = error.localizedDescription
        }
    }

    private func startSending(using link: DirectLink) throws {
        guard let outgoing, !waitingForReceipt else { throw DirectError("Неожиданное подтверждение файла") }
        let file = try FileHandle(forReadingFrom: outgoing.url)
        waitingForReceipt = true
        transfer = "Передаю \(outgoing.name)…"
        sendChunk(file, remaining: outgoing.size, hasher: SHA256(), using: link)
    }

    private func sendChunk(_ file: FileHandle, remaining: Int64, hasher: SHA256, using link: DirectLink) {
        guard self.link === link, outgoing != nil else { try? file.close(); return }
        do {
            if remaining == 0 {
                try file.close()
                link.send(.done, Data(hasher.finalize()))
                transfer = "Проверка файла на устройстве получателя"
                return
            }
            guard let bytes = try file.read(upToCount: Int(min(remaining, 32_768))), !bytes.isEmpty else {
                throw DirectError("Файл изменился во время передачи")
            }
            var next = hasher
            next.update(data: bytes)
            link.send(.chunk, bytes) { [weak self, weak link] sent in
                guard sent, let self, let link else { try? file.close(); return }
                self.sendChunk(file, remaining: remaining - Int64(bytes.count), hasher: next, using: link)
            }
        } catch {
            try? file.close()
            link.close(error.localizedDescription)
        }
    }

    func callPeer() {
        guard let link, peer != nil, call == nil, outgoing == nil, receiving == nil, incoming == nil else { return }
        call = .outgoing
        link.send(.call)
    }

    func answerCall() {
        guard call == .incoming else { return }
        link?.send(.answer)
        startCall()
    }

    func hangUp() {
        if call != nil { link?.send(.hangup) }
        stopCall()
    }

    private func startCall() {
        call = .active
        let audio = CallAudio()
        self.audio = audio
        audio.onError = { [weak self] reason in self?.status = reason; self?.hangUp() }
        audio.onAudio = { [weak self, weak audio] pcm in
            DispatchQueue.main.async {
                guard let self, let audio, self.audio === audio, self.pendingAudio < 3 else { return }
                self.pendingAudio += 1
                self.link?.send(.audio, pcm) { [weak self, weak audio] _ in
                    guard let self, let audio, self.audio === audio else { return }
                    self.pendingAudio -= 1
                }
            }
        }
        audio.start()
    }

    private func stopCall() {
        audio?.stop()
        audio = nil
        pendingAudio = 0
        call = nil
    }

    private func receive(_ type: DirectPacket, _ data: Data, link: DirectLink) throws {
        guard let peer else { return }
        switch type {
        case .keepalive: return
        case .hello, .welcome:
            throw DirectError("Повторная аутентификация")
        case .text:
            guard !data.isEmpty, data.count <= 8_192, let text = String(data: data, encoding: .utf8) else {
                throw DirectError("Некорректное сообщение")
            }
            append(DirectMessage(text: text, mine: false), for: peer.id)
        case .offer:
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = fields["name"] as? String, !name.isEmpty, name.utf8.count <= 360,
                  let size = fields["size"] as? Int64, size >= 0, size <= Self.maxFile else {
                throw DirectError("Некорректное предложение файла")
            }
            guard incoming == nil, receiving == nil, call == nil, outgoing == nil else { link.send(.decline); return }
            incoming = DirectOffer(name: name, size: size)
        case .accept:
            try startSending(using: link)
        case .decline:
            guard outgoing != nil, !waitingForReceipt else { throw DirectError("Неожиданный отказ") }
            outgoing?.url.stopAccessingSecurityScopedResource()
            outgoing = nil
            transfer = "Собеседник отклонил файл"
        case .chunk:
            guard let receiving else { throw DirectError("Файл не принят") }
            try receiving.add(data)
        case .done:
            guard let receiving else { throw DirectError("Файл не принят") }
            fileURL = try receiving.finish(data)
            self.receiving = nil
            transfer = "Файл получен и проверен"
            link.send(.received)
        case .received:
            guard waitingForReceipt, outgoing != nil else { throw DirectError("Неожиданное подтверждение файла") }
            outgoing?.url.stopAccessingSecurityScopedResource()
            outgoing = nil
            waitingForReceipt = false
            transfer = "Файл доставлен"
        case .call:
            if call == .outgoing || call == .active { return }
            guard call == nil, incoming == nil, receiving == nil, outgoing == nil else { link.send(.hangup); return }
            call = .incoming
        case .answer:
            if call == .outgoing { startCall() }
        case .hangup: stopCall()
        case .audio:
            guard call == .active, !data.isEmpty, data.count <= 4096, data.count.isMultiple(of: 2) else { return }
            audio?.receive(data)
        }
    }

    private func discardIncoming() {
        receiving?.discard()
        receiving = nil
    }

    private static func isHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sameToken(_ left: String, _ right: String) -> Bool {
        left.utf8.count == right.utf8.count &&
        zip(left.utf8, right.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private final class IncomingFile {
    private let offer: DirectOffer
    private let temporary: URL
    private let file: FileHandle
    private var remaining: Int64
    private var hasher = SHA256()

    init(_ offer: DirectOffer) throws {
        self.offer = offer
        remaining = offer.size
        let temporary = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        self.temporary = temporary
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw DirectError("Не удалось создать временный файл")
        }
        do {
            file = try FileHandle(forWritingTo: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func add(_ data: Data) throws {
        guard !data.isEmpty, Int64(data.count) <= remaining else { throw DirectError("Файл превышает объявленный размер") }
        try file.write(contentsOf: data)
        hasher.update(data: data)
        remaining -= Int64(data.count)
    }

    func finish(_ digest: Data) throws -> URL {
        guard remaining == 0, Data(hasher.finalize()) == digest else {
            throw DirectError("Контрольная сумма файла не совпала")
        }
        try file.close()
        let safe = offer.name.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "_")
        let folder = URL.documentsDirectory.appendingPathComponent("Received", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(safe.isEmpty || safe == "." || safe == ".." ? "Файл" : safe)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func discard() {
        try? file.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}

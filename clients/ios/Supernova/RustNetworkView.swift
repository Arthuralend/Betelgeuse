import SwiftUI
import Security
import CoreImage.CIFilterBuiltins
import BetelgeuseCore

struct RustContact: Identifiable {
    var id: String
    var name: String
}

struct RustMessage: Identifiable {
    var id: String
    var text: String
    var mine: Bool
    var delivered: Bool
}

final class RustNetwork: ObservableObject {
    @Published var ownID = ""
    @Published var status = "Запуск ядра…"
    @Published var contacts: [RustContact] = []
    @Published var messages: [RustMessage] = []
    @Published var selected = ""
    @Published var invitation = ""
    @Published var lastRecord = ""
    @Published var ready = false
    private var engine: OpaquePointer?
    private var timer: Timer?

    deinit {
        timer?.invalidate()
        if let engine { bgl_close(engine) }
    }

    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { bgl_string_free(pointer) }
        return String(validatingUTF8: pointer)
    }

    func start() {
        guard engine == nil else { return }
        do {
            let secret = try Self.loadIdentity()
            let directory = URL.applicationSupportDirectory.appendingPathComponent("BetelgeuseRust", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let options = #"{"listen":["/ip4/0.0.0.0/tcp/0","/ip4/0.0.0.0/udp/0/quic-v1"],"server":false}"#
            guard let instance = bgl_open(directory.path, secret, options) else {
                throw DirectError(Self.take(bgl_last_error()) ?? "Ошибка сетевого ядра")
            }
            engine = instance
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
        } catch { status = error.localizedDescription }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let engine { bgl_close(engine) }
        engine = nil
        ready = false
        status = "Сеть остановлена"
    }

    private static func loadIdentity() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "am.supernova.local.rust",
                                    kSecAttrAccount as String: "ed25519"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(lookup as CFDictionary, &result)
        if code == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) { return token }
        guard code == errSecItemNotFound else { throw DirectError("Не удалось открыть ключ профиля (Keychain)") }
        guard let secret = take(bgl_generate_identity()) else { throw DirectError("Не удалось создать профиль") }
        var record = query
        record[kSecValueData as String] = Data(secret.utf8)
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else {
            throw DirectError("Не удалось сохранить ключ профиля")
        }
        return secret
    }

    func send(_ data: [String: Any]) {
        guard let engine, let bytes = try? JSONSerialization.data(withJSONObject: data),
              let json = String(data: bytes, encoding: .utf8) else { return }
        if bgl_send(engine, json) != 0 { status = Self.take(bgl_last_error()) ?? "Команда недоступна" }
    }

    func choose(_ contact: String) {
        selected = contact
        messages = []
        send(["op": "history", "peer": contact])
    }

    private func refresh() {
        if !selected.isEmpty { send(["op": "history", "peer": selected]) }
    }

    private func poll() {
        guard let engine else { return }
        for _ in 0..<32 {
            guard let text = Self.take(bgl_poll(engine)), let bytes = text.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { break }
            switch event["event"] as? String {
            case "started":
                ownID = event["peer"] as? String ?? ""
                status = "Узел запущен"
                ready = true
                send(["op": "contacts"])
            case "listen":
                if let address = event["address"] as? String, address.contains("/p2p-circuit/") { status = "Маршрут через relay готов" }
            case "connected":
                status = event["route"] as? String == "relay" ? "Подключение через relay" : "Прямое подключение"
            case "direct_upgrade":
                if event["ok"] as? Bool == true { status = "Прямое P2P-соединение" }
            case "relay_reserved":
                status = "Ретранслятор доступен"
            case "connection_error", "error", "fatal":
                status = event["error"] as? String ?? "Ошибка сети"
                if event["event"] as? String == "fatal" { ready = false }
            case "invite":
                invitation = event["link"] as? String ?? ""
            case "contact":
                send(["op": "contacts"])
            case "contacts":
                contacts = (event["contacts"] as? [[String: Any]] ?? []).compactMap { item in
                    guard let peer = item["peer"] as? String else { return nil }
                    return RustContact(id: peer, name: item["name"] as? String ?? String(peer.prefix(12)))
                }
            case "get":
                if event["ok"] as? Bool == true {
                    let record = event["record"] as? [String: Any]
                    let body = record?["body"] as? [String: Any]
                    let payload = body?["payload"] as? [String: Any]
                    lastRecord = payload?["name"] as? String ?? "Подписанная запись найдена"
                    status = "Запись DHT проверена"
                } else { status = "Запись не найдена" }
            case "put":
                status = event["ok"] as? Bool == true ? "Запись опубликована" : "Публикация не подтверждена"
            case "queued", "message", "delivery": refresh()
            case "history":
                if event["peer"] as? String == selected {
                    messages = (event["messages"] as? [[String: Any]] ?? []).compactMap { item in
                        guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
                        return RustMessage(id: id, text: text, mine: item["mine"] as? Bool ?? false,
                                           delivered: item["delivered"] as? Bool ?? false)
                    }
                }
            default: break
            }
        }
    }
}

struct RustNetworkView: View {
    @StateObject private var core = RustNetwork()
    @AppStorage("rust.displayname") private var name = ""
    @AppStorage("rust.bootstrap") private var bootstrap = ""
    @State private var input = ""
    @State private var peer = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(core.status).foregroundStyle(.secondary)
                    if !core.ownID.isEmpty {
                        Text(core.ownID).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Копировать Peer ID") { UIPasteboard.general.string = core.ownID }
                    }
                    TextField("Имя профиля", text: $name)
                    TextField("Адрес узла /p2p/…", text: $bootstrap).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Подключить узел") { core.send(["op":"connect","address":bootstrap]) }
                        Spacer()
                        Button("Резервировать relay") { core.send(["op":"reserve_relay","address":bootstrap]) }
                    }.buttonStyle(.borderless)
                    Button("Опубликовать профиль и маршруты") {
                        core.send(["op":"put","name":name.isEmpty ? NSNull() : name as Any])
                        core.send(["op":"publish_routes"])
                    }
                    Button("Создать приглашение") {
                        core.send(["op":"invite","name":name.isEmpty ? NSNull() : name as Any])
                    }
                    if !core.invitation.isEmpty {
                        ShareLink(item: core.invitation) { Label("Поделиться приглашением", systemImage: "square.and.arrow.up") }
                        Button("Копировать ссылку") { UIPasteboard.general.string = core.invitation }
                        if let image = qr(core.invitation) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 210).frame(maxWidth: .infinity)
                        }
                    }
                }.disabled(!core.ready)
                Section("Контакты") {
                    TextField("Вставьте приглашение", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Добавить контакт") { core.send(["op":"import","link":input]); input = "" }
                    TextField("Поиск по Peer ID", text: $peer).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Найти в DHT") { core.send(["op":"get","peer":peer]); }
                    if !core.lastRecord.isEmpty { Text(core.lastRecord) }
                    ForEach(core.contacts) { contact in
                        Button {
                            core.choose(contact.id)
                        } label: {
                            HStack { Text(contact.name); Spacer(); if core.selected == contact.id { Image(systemName: "checkmark") } }
                        }
                    }
                }.disabled(!core.ready)
                if !core.selected.isEmpty {
                    Section("Чат") {
                        ForEach(core.messages) { message in
                            HStack {
                                if message.mine { Spacer() }
                                VStack(alignment: .leading) {
                                    Text(message.text)
                                    if message.mine { Text(message.delivered ? "Доставлено" : "В очереди").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(8).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                if !message.mine { Spacer() }
                            }
                        }
                        TextField("Сообщение", text: $text)
                        Button("Отправить") { core.send(["op":"send","peer":core.selected,"text":text]); text = "" }
                        Button("Повторить отправку") { core.send(["op":"retry","peer":core.selected]) }
                    }
                }
                Section { if core.ready { Button("Остановить сеть", action:core.stop) } else { Button("Запустить сеть", action:core.start) } }
            }
            .navigationTitle("Бетельгейзе")
            .onAppear { core.start() }
        }
    }

    private func qr(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

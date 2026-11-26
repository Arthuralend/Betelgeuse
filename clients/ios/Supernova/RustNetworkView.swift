import SwiftUI
import Security
import CoreImage.CIFilterBuiltins
import BetelgeuseCore
import UniformTypeIdentifiers

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

struct RustTransfer: Identifiable {
    var id: String
    var peer: String
    var name: String
    var size: Int64
    var received: Int64 = 0
    var state: String
    var path: String?
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
    @Published var transfers: [RustTransfer] = []
    var onCallEvent: (([String:Any]) -> Void)?
    var onStop: (() -> Void)?
    private var pendingStaged: URL?
    private var staged: [String:URL] = [:]
    private var engine: OpaquePointer?
    private var timer: Timer?

    deinit {
        timer?.invalidate()
        if let engine { bgl_close(engine) }
        if let pendingStaged { try? FileManager.default.removeItem(at:pendingStaged) }
        for folder in staged.values { try? FileManager.default.removeItem(at:folder) }
    }

    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { bgl_string_free(pointer) }
        return String(validatingUTF8: pointer)
    }

    func start() {
        guard !ready else { return }
        if engine != nil { stop() }
        status = "Запуск ядра…"
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
        onStop?()
        timer?.invalidate()
        timer = nil
        if let engine { bgl_close(engine) }
        engine = nil
        if let pendingStaged { try? FileManager.default.removeItem(at:pendingStaged) }
        pendingStaged=nil
        for folder in staged.values { try? FileManager.default.removeItem(at:folder) }
        staged.removeAll()
        transfers.removeAll()
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

    @discardableResult func send(_ data: [String: Any]) -> Bool {
        guard let engine, let bytes = try? JSONSerialization.data(withJSONObject: data),
              let json = String(data: bytes, encoding: .utf8) else { return false }
        if bgl_send(engine, json) != 0 { status = Self.take(bgl_last_error()) ?? "Команда недоступна"; return false }
        return true
    }

    func sendFile(_ url: URL, peer: String) {
        guard pendingStaged == nil, !peer.isEmpty else { return }
        let folder = URL.temporaryDirectory.appendingPathComponent("betelgeuse-outgoing-" + UUID().uuidString, isDirectory:true)
        pendingStaged = folder
        status = "Подготовка файла…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                guard values.isRegularFile == true, let size=values.fileSize, size <= 256 * 1024 * 1024 else {
                    throw DirectError("Выберите файл до 256 МБ")
                }
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let copy = folder.appendingPathComponent("payload")
                try FileManager.default.copyItem(at:url,to:copy)
                DispatchQueue.main.async {
                    guard let self, self.pendingStaged == folder else { try? FileManager.default.removeItem(at:folder); return }
                    if !self.send(["op":"file_send","peer":peer,"path":copy.path,"name":url.lastPathComponent]) {
                        self.pendingStaged=nil
                        try? FileManager.default.removeItem(at:folder)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at:folder)
                DispatchQueue.main.async { self?.pendingStaged=nil; self?.status=error.localizedDescription }
            }
        }
    }

    func fileCommand(_ verb:String, _ item:RustTransfer) {
        send(["op":"file_"+verb,"peer":item.peer,"id":item.id])
    }

    private func updateTransfer(_ id:String, mutate:(inout RustTransfer)->Void) {
        if let index=transfers.firstIndex(where:{$0.id==id}) { mutate(&transfers[index]) }
    }

    private func fileEvent(_ event:[String:Any]) {
        let kind=event["event"] as? String ?? ""
        if kind=="file_prepare_failed" {
            if let pendingStaged { try? FileManager.default.removeItem(at:pendingStaged) }
            pendingStaged=nil
            status=event["error"] as? String ?? "Ошибка файла"
            return
        }
        if kind=="file_action_failed" || kind=="file_ack_failed" {
            status=event["error"] as? String ?? "Ошибка файла"
            return
        }
        if kind=="files" {
            for item in event["files"] as? [[String:Any]] ?? [] {
                var value=item; value["event"]="file_received"; fileEvent(value)
            }
            return
        }
        guard let id=event["id"] as? String, let peer=event["peer"] as? String else { return }
        switch kind {
        case "file_offer", "file_offered", "file_received":
            let name=event["name"] as? String ?? "Файл"
            let size=event["size"] as? Int64 ?? 0
            let state=kind=="file_offer" ? "offer" : kind=="file_offered" ? "sent_offer" : "received"
            let transfer=RustTransfer(id:id,peer:peer,name:name,size:size,received:state=="received" ? size : 0,state:state,path:event["path"] as? String)
            transfers.removeAll{$0.id==id};transfers.insert(transfer,at:0)
            if kind=="file_offered", let folder=pendingStaged { staged[id]=folder; pendingStaged=nil }
        case "file_started": updateTransfer(id) { $0.state="receiving" }
        case "file_progress":
            updateTransfer(id) { item in item.received=event["received"] as? Int64 ?? item.received; item.state=(event["active"] as? Bool == false) ? "paused" : "receiving" }
        case "file_paused": updateTransfer(id) { $0.state="paused" }
        case "file_delivered","file_failed","file_cancelled":
            updateTransfer(id) { $0.state=kind=="file_delivered" ? "delivered" : kind=="file_failed" ? "failed" : "cancelled" }
            if let folder=staged.removeValue(forKey:id) { try? FileManager.default.removeItem(at:folder) }
            if let error=event["error"] as? String { status=error }
        default: break
        }
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
                send(["op": "files"])
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
                if event["event"] as? String == "fatal" {
                    let failure = status
                    stop()
                    status = failure
                    return
                }
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
            case "call_signal","call_delivery": onCallEvent?(event)
            case "file_offer","file_offered","file_received","file_progress","file_paused","file_delivered","file_failed","file_cancelled","file_prepare_failed","file_action_failed","file_started","file_ack_failed","files": fileEvent(event)
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
    @StateObject private var call = RustCall()
    @AppStorage("rust.ice") private var ice = ""
    @State private var turnUser=""
    @State private var turnPassword=""
    @State private var pickingFile=false
    private var settings:CallIceSettings { CallIceSettings(urls:ice,username:turnUser,password:turnPassword) }
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
                Section("WebRTC") {
                    TextField("STUN/TURN URL (необязательно)",text:$ice).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("TURN логин",text:$turnUser).textInputAutocapitalization(.never)
                    SecureField("TURN пароль",text:$turnPassword)
                    if !call.status.isEmpty { Text(call.status).foregroundStyle(.secondary) }
                    if call.active {
                        if call.phase == .incoming { Button("Ответить",action:call.answer) }
                        if let remote=call.remoteVideo { RustVideo(track:remote).frame(height:260).background(.black) }
                        if let local=call.localVideo { RustVideo(track:local).frame(height:120).background(.black) }
                        if call.phase == .connected || call.phase == .connecting {
                            HStack {
                                Button(call.muted ? "Включить микрофон" : "Выключить микрофон",action:call.toggleMute)
                                if call.video { Button(call.cameraDisabled ? "Включить камеру" : "Выключить камеру",action:call.toggleCamera) }
                            }.buttonStyle(.borderless)
                        }
                        Button(call.phase == .incoming ? "Отклонить" : "Завершить",role:.destructive,action:call.hangup)
                    } else if !core.selected.isEmpty {
                        HStack {
                            Button("Аудиозвонок") { call.dial(core.selected,video:false,settings:settings) }
                            Button("Видеозвонок") { call.dial(core.selected,video:true,settings:settings) }
                        }.buttonStyle(.borderless)
                    }
                }.disabled(!core.ready)
                if !core.selected.isEmpty {
                    Section("Чат") {
                        Button("Обновить маршрут контакта") { core.send(["op":"get","peer":core.selected,"kind":"routes"]) }
                        Button("Отправить файл") { pickingFile=true }
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
                if !core.transfers.isEmpty {
                    Section("Файлы") {
                        ForEach(core.transfers) { item in
                            VStack(alignment:.leading,spacing:7) {
                                Text(item.name).font(.headline)
                                Text(ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file)).font(.caption)
                                switch item.state {
                                case "offer":
                                    HStack {
                                        Button("Принять") { core.fileCommand("accept",item) }
                                        Button("Отклонить",role:.destructive) { core.fileCommand("cancel",item) }
                                    }.buttonStyle(.borderless)
                                case "receiving", "paused":
                                    ProgressView(value:Double(item.received),total:Double(max(item.size,1)))
                                    HStack {
                                        Button(item.state=="paused" ? "Продолжить" : "Пауза") { core.fileCommand(item.state=="paused" ? "resume" : "pause",item) }
                                        Button("Отмена",role:.destructive) { core.fileCommand("cancel",item) }
                                    }.buttonStyle(.borderless)
                                case "received":
                                    if let path=item.path { ShareLink(item:URL(fileURLWithPath:path)) { Label("Сохранить файл",systemImage:"square.and.arrow.up") } }
                                case "sent_offer":
                                    Text("Ожидает получателя").foregroundStyle(.secondary)
                                    Button("Отмена",role:.destructive) { core.fileCommand("cancel",item) }
                                case "delivered": Text("Доставлено")
                                case "cancelled": Text("Отменено")
                                default: Text("Ошибка передачи").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section { if core.ready { Button("Остановить сеть", action:core.stop) } else { Button("Запустить сеть", action:core.start) } }
            }
            .navigationTitle("Бетельгейзе")
            .fileImporter(isPresented:$pickingFile,allowedContentTypes:[.item]) { result in
                if case .success(let url)=result { core.sendFile(url,peer:core.selected) }
            }
            .onAppear {
                call.sender = { [weak core] in core?.send($0) ?? false }
                core.onCallEvent = { [weak call] event in call?.receive(event,settings:settings) }
                core.onStop = { [weak call] in call?.hangup() }
                core.start()
            }
            .onDisappear { call.hangup() }
            .onChange(of:ice) { _ in core.onCallEvent = { [weak call] event in call?.receive(event,settings:settings) } }
            .onChange(of:turnUser) { _ in core.onCallEvent = { [weak call] event in call?.receive(event,settings:settings) } }
            .onChange(of:turnPassword) { _ in core.onCallEvent = { [weak call] event in call?.receive(event,settings:settings) } }
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

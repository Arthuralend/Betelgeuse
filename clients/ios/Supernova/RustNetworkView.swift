import SwiftUI
import Security
import CoreImage.CIFilterBuiltins
import BetelgeuseCore
import UniformTypeIdentifiers
import Network

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

struct RustPairOffer: Identifiable {
    let id:String
    let peer:String
    let name:String
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
    @Published var starting = false
    @Published var tcpPort = 0
    @Published var networkStatus = "Ожидание сети"
    @Published var pairStatus = ""
    @Published var pairOffers:[RustPairOffer] = []
    private var appleInviteCallbacks:[String:(String?)->Void]=[:]
    private var previewCallbacks:[String:(String?,String?)->Void]=[:]
    private var startupTimeout:DispatchWorkItem?
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
        guard !ready,!starting else { return }
        if engine != nil { stop() }
        status = "Запуск ядра…"
        starting = true
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
            // Continue polling while the keyboard, lists and scrolling change run-loop modes.
            if let timer { RunLoop.main.add(timer,forMode:.common) }
            let timeout=DispatchWorkItem{[weak self] in
                guard let self,!self.ready,self.starting else{return}
                self.stop()
                self.status="Ядро не ответило. Нажмите «Запустить сеть»."
            }
            startupTimeout=timeout
            DispatchQueue.main.asyncAfter(deadline:.now()+15,execute:timeout)
        } catch { starting=false; status = error.localizedDescription }
    }

    func stop() {
        onStop?()
        startupTimeout?.cancel();startupTimeout=nil;starting=false
        timer?.invalidate()
        timer = nil
        if let engine { bgl_close(engine) }
        engine = nil
        if let pendingStaged { try? FileManager.default.removeItem(at:pendingStaged) }
        pendingStaged=nil
        for folder in staged.values { try? FileManager.default.removeItem(at:folder) }
        staged.removeAll()
        transfers.removeAll()
        ready = false;tcpPort=0;pairOffers.removeAll()
        appleInviteCallbacks.removeAll();previewCallbacks.removeAll()
        networkStatus="Сеть остановлена"
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

    static func cleanName(_ name:String)->String {
        var value=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))
        while value.utf8.count>120 {value.removeLast()}
        return value
    }
    static var bundledNodes:[String] {
        guard let url=Bundle.main.url(forResource:"bootstrap-local",withExtension:"json"),
              let data=try? Data(contentsOf:url), data.count<8192,
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let nodes=value["nodes"] as? [String] else{return []}
        return Array(nodes.prefix(8))
    }

    func configure(name:String,enabled:Bool,custom:[String]) {
        let clean=Self.cleanName(name)
        let nodes=Array(NSOrderedSet(array:Self.bundledNodes+custom).array.compactMap{$0 as? String}.prefix(8))
        send(["op":"configure_network","settings":["enabled":enabled,"name":clean.isEmpty ? NSNull() : clean as Any,"addresses":nodes]])
        if nodes.isEmpty { networkStatus="Нет настроенного интернет-узла" }
    }

    func pair(address:String,name:String) { 
        let value=Self.cleanName(name)
        send(["op":"pair_request","address":address,"name":value.isEmpty ? NSNull() : value as Any])
    }
    func acceptPair(_ offer:RustPairOffer,name:String) {
        let value=Self.cleanName(name)
        send(["op":"pair_accept","id":offer.id,"name":value.isEmpty ? NSNull() : value as Any])
    }
    func declinePair(_ offer:RustPairOffer) {
        send(["op":"pair_decline","id":offer.id])
    }
    func appleInvite(name:String,completion:@escaping(String?)->Void) {
        guard appleInviteCallbacks.count<8 else{completion(nil);return}
        let token=UUID().uuidString
        appleInviteCallbacks[token]=completion
        let value=Self.cleanName(name)
        if !send(["op":"apple_invitation","token":token,"name":value.isEmpty ? NSNull() : value as Any]) {
            appleInviteCallbacks.removeValue(forKey:token)?(nil)
        }
    }
    func previewApple(_ link:String,completion:@escaping(String?,String?)->Void) {
        guard previewCallbacks.count<8 else{completion(nil,nil);return}
        let token=UUID().uuidString;previewCallbacks[token]=completion
        if !send(["op":"preview_invitation","link":link,"token":token]) {previewCallbacks.removeValue(forKey:token)?(nil,nil)}
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
                startupTimeout?.cancel();startupTimeout=nil;starting=false
                ready = true
                send(["op": "contacts"])
                send(["op": "files"])
            case "listen":
                if let port=event["tcp_port"] as? Int,port>0 {tcpPort=port}
                if let address = event["address"] as? String, address.contains("/p2p-circuit/") { status = "Маршрут через relay готов" }
            case "connected":
                status = event["route"] as? String == "relay" ? "Подключение через relay" : "Прямое подключение"
            case "direct_upgrade":
                if event["ok"] as? Bool == true { status = "Прямое P2P-соединение" }
            case "relay_reserved":
                status = "Ретранслятор доступен"
            case "network_state":
                switch event["state"] as? String {
                case "configured": networkStatus=(event["nodes"] as? Int ?? 0)>0 ? "Автоматическое подключение…" : "Локальный режим"
                case "connected": networkStatus="Узел доступен. Устанавливаю маршрут…"
                case "ready":networkStatus="Интернет P2P готов"
                case "retrying":networkStatus="Переподключение…"
                default:break
                }
            case "pair_offer":
                if let id=event["id"] as? String,let peer=event["peer"] as? String {
                    pairOffers.removeAll{$0.id==id}
                    pairOffers.append(RustPairOffer(id:id,peer:peer,name:event["name"] as? String ?? "Бетельгейзе"))
                }
            case "pair_sent":pairStatus="Ожидаю подтверждения контакта…"
            case "pair_result","pair_expired":
                if let id=event["id"] as? String {pairOffers.removeAll{$0.id==id}}
                pairStatus=(event["event"] as? String=="pair_expired") ? "Запрос закрыт" : (event["ok"] as? Bool==true ? "Контакт добавлен" : "Запрос не принят или недоступен")
            case "apple_invite":
                if let token=event["token"] as? String {appleInviteCallbacks.removeValue(forKey:token)?(event["ok"] as? Bool==true ? event["link"] as? String:nil)}
            case "invite_preview":
                if let token=event["token"] as? String {previewCallbacks.removeValue(forKey:token)?(event["peer"] as? String,event["name"] as? String)}
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
    @StateObject private var nearby=NearbyDiscovery()
    @StateObject private var applePair=ApplePair()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rust.autoNetwork") private var autoNetwork=true
    @AppStorage("rust.nearbyEnabled") private var nearbyEnabled=true
    @AppStorage("rust.bootstrap") private var customNode=""
    @State private var advanced=false
    @State private var networkMonitor:NWPathMonitor?
    @State private var visible=false
    @AppStorage("rust.ice") private var ice = ""
    @State private var turnUser=""
    @State private var turnPassword=""
    @State private var pickingFile=false
    private var settings:CallIceSettings { CallIceSettings(urls:ice,username:turnUser,password:turnPassword) }
    @AppStorage("rust.displayname") private var name = ""
    @State private var bootstrap = ""
    @State private var input = ""
    @State private var peer = ""
    @State private var text = ""

    private func configure() {
        guard core.ready else{return}
        let custom=customNode.isEmpty ? [] : [customNode]
        core.configure(name:name,enabled:autoNetwork,custom:custom)
        let display=RustNetwork.cleanName(name)
        applePair.createInvite={ [weak core] done in
            guard let core else{done(nil);return}
            core.appleInvite(name:display,completion:done)
        }
    }
    private func discover() {
        guard visible,scenePhase == .active,nearbyEnabled,core.ready else{nearby.stop();applePair.stop();return}
        let alias=RustNetwork.cleanName(name)
        let display=alias.isEmpty ? "Бетельгейзе":String(alias.prefix(40))
        if core.tcpPort>0 {nearby.start(peer:core.ownID,port:core.tcpPort,name:display)}
        applePair.start(peer:core.ownID,name:display)
    }
    private func monitor() {
        guard networkMonitor==nil else{return}
        let value=NWPathMonitor()
        var prior:String?
        value.pathUpdateHandler={ [weak core] path in
            let key="\(path.status)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))-\(path.usesInterfaceType(.wiredEthernet))"
            let changed=prior != nil && prior != key && path.status == .satisfied
            prior=key
            DispatchQueue.main.async {
                guard let core,core.ready else{return}
                core.send(["op":"network_changed","reset":changed])
            }
        }
        networkMonitor=value;value.start(queue:DispatchQueue(label:"betelgeuse.network.status"))
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Сеть") {
                    Label(core.ready ? core.networkStatus : core.status,systemImage:core.ready ? "network" : "exclamationmark.circle")
                        .foregroundStyle(core.ready ? Color.green : Color.secondary)
                    if core.starting { ProgressView("Запуск сети…") }
                    TextField("Ваше имя",text:$name)
                        .onSubmit{configure();discover()}
                    Button("Сохранить имя"){configure();discover()}
                    Toggle("Автоматическое подключение",isOn:$autoNetwork)
                    Toggle("Устройства рядом",isOn:$nearbyEnabled)
                    DisclosureGroup("Дополнительные настройки",isExpanded:$advanced) {
                        Text(core.status).font(.caption).foregroundStyle(.secondary)
                        if !core.ownID.isEmpty {
                            Text(core.ownID).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Копировать Peer ID"){UIPasteboard.general.string=core.ownID}
                        }
                        TextField("Добавить доверенный узел /p2p/…",text:$bootstrap).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Сохранить дополнительный узел"){customNode=bootstrap.trimmingCharacters(in:.whitespacesAndNewlines);configure()}
                        Button("Сбросить дополнительный узел"){customNode="";bootstrap="";configure()}
                        Button("Обновить профиль и маршруты"){configure();core.send(["op":"network_changed"])}
                    }
                }
                Section("Рядом") {
                    if !nearbyEnabled {Text("Поиск отключён").foregroundStyle(.secondary)}
                    else {
                        Text(nearby.status).font(.caption).foregroundStyle(.secondary)
                        if nearby.peers.isEmpty && applePair.peers.isEmpty {Text("Откройте Бетельгейзе на другом устройстве").foregroundStyle(.secondary)}
                        ForEach(nearby.peers.filter{p in !core.contacts.contains{$0.id==p.id}}){item in
                            HStack {
                                VStack(alignment:.leading){Text(item.name);Text("Wi-Fi · "+String(item.id.suffix(8))).font(.caption).foregroundStyle(.secondary)}
                                Spacer()
                                Button("Добавить"){core.pair(address:item.address,name:name)}.buttonStyle(.bordered)
                            }
                        }
                        ForEach(applePair.peers.filter{p in !nearby.peers.contains{$0.id==p.id} && !core.contacts.contains{$0.id==p.id}}){item in
                            HStack {
                                VStack(alignment:.leading){Text(item.name);Text("Apple рядом · "+String(item.id.suffix(8))).font(.caption).foregroundStyle(.secondary)}
                                Spacer()
                                Button("Добавить"){applePair.request(item)}.buttonStyle(.bordered)
                            }
                        }
                    }
                    ForEach(core.pairOffers){offer in
                        VStack(alignment:.leading){
                            Text("\(offer.name) предлагает добавить контакт")
                            Text("Проверенный Peer ID: "+String(offer.peer.suffix(12))).font(.caption)
                            HStack {
                                Button("Принять"){core.acceptPair(offer,name:name)}.buttonStyle(.borderedProminent)
                                Button("Отклонить",role:.destructive){core.declinePair(offer)}.buttonStyle(.bordered)
                            }
                        }
                    }
                    if let offer=applePair.offer {
                        VStack(alignment:.leading){
                            Text("\(offer.name) предлагает добавить контакт")
                            Text("Проверенный Peer ID: "+String(offer.peer.suffix(12))).font(.caption)
                            HStack {
                                Button("Принять"){applePair.accept()}.buttonStyle(.borderedProminent)
                                Button("Отклонить",role:.destructive){applePair.decline()}.buttonStyle(.bordered)
                            }
                        }
                    }
                    if !core.pairStatus.isEmpty {Text(core.pairStatus).font(.caption).foregroundStyle(.secondary)}
                    if !applePair.status.isEmpty {Text(applePair.status).font(.caption).foregroundStyle(.secondary)}
                }.disabled(!core.ready)
                Section("Приглашения вручную (необязательно)") {
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
                    if !call.active && !core.selected.isEmpty {
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
                Section { if core.ready { Button("Остановить сеть", action:core.stop) } else { Button("Запустить сеть", action:core.start).disabled(core.starting) } }
            }
            .navigationTitle("Бетельгейзе")
            .fileImporter(isPresented:$pickingFile,allowedContentTypes:[.item]) { result in
                if case .success(let url)=result { core.sendFile(url,peer:core.selected) }
            }
            .onAppear {
                visible=true
                bootstrap=customNode
                applePair.preview={ [weak core] link,done in
                    guard let core else {done(nil,nil);return}
                    core.previewApple(link,completion:done)
                }
                applePair.importInvite={ [weak core] link,peer in _ = core?.send(["op":"import_verified","link":link,"expected_peer":peer]) }
                call.sender = { [weak core] in core?.send($0) ?? false }
                core.onCallEvent = { [weak call] event in call?.receive(event,settings:settings) }
                core.onStop = { [weak call,weak nearby,weak applePair] in call?.hangup();nearby?.stop();applePair?.stop() }
                core.start();monitor()
                if core.ready {configure();discover()}
            }
            .fullScreenCover(isPresented: Binding(get: { call.active }, set: { _ in })) {
                RustCallScreen(call: call, name: core.contacts.first(where: { $0.id == call.peer })?.name ?? String(call.peer.prefix(16)))
            }
            .onDisappear {guard !call.active else { return };visible=false;nearby.stop();applePair.stop();networkMonitor?.cancel();networkMonitor=nil}
            .onChange(of:core.ready){if $0{configure();discover()}}
            .onChange(of:core.tcpPort){_ in discover()}
            .onChange(of:autoNetwork){_ in configure()}
            .onChange(of:nearbyEnabled){_ in discover()}
            .onChange(of:scenePhase){phase in
                if phase == .active {if !core.ready{core.start()};core.send(["op":"network_changed"]);discover()}
                else if phase == .background {nearby.stop();applePair.stop()}
            }
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

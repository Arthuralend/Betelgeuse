import Foundation
import MultipeerConnectivity
import CryptoKit
import UIKit
import AVFoundation

struct NearbyPeer: Identifiable {
    let id: String
    let peerID: MCPeerID
    let name: String
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let mine: Bool
    let at: Date
}

enum CallPhase: String {
    case outgoing
    case incoming
    case active
}

struct ActiveCall: Identifiable {
    let id: String
    let peerIdentityId: String
    var peerName: String
    var outgoing: Bool
    var phase: CallPhase
    var startedAt: Date
    var muted: Bool = false
    var speaker: Bool = true
}

struct Friend: Codable, Identifiable {
    var id: String { peerIdentityId }
    let peerIdentityId: String
    var name: String
    var addedAt: Date
}

final class MeshService: NSObject, ObservableObject {
    @Published var nearby: [NearbyPeer] = []
    @Published var messages: [ChatMessage] = []
    @Published var connectedName: String?
    @Published var fingerprint: String?
    @Published var status: String = "Ищу устройства рядом…"
    @Published var displayName: String
    @Published var friends: [Friend] = []
    @Published var connectedIdentityId: String?
    @Published var unread: Int = 0
    @Published var call: ActiveCall?
    @Published var callError: String?

    private let serviceType = "supernova"
    private let identityId: String
    private let dhPrivate: Curve25519.KeyAgreement.PrivateKey
    private let myPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peerDh: [String: Data] = [:]
    private var peerIdentity: [String: String] = [:]
    private var keys: [String: SymmetricKey] = [:]
    private var seen: Set<String> = []
    private var connectedPeer: MCPeerID?
    private let autoConnect = ProcessInfo.processInfo.arguments.contains("--auto-connect")
    private let autoMessage = ProcessInfo.processInfo.arguments.contains("--auto-message")
    private var autoSent = false
    private let autoCall = ProcessInfo.processInfo.arguments.contains("--auto-call")
    private let autoAnswer = ProcessInfo.processInfo.arguments.contains("--auto-answer")
    private let skipCallAudio = ProcessInfo.processInfo.arguments.contains("--no-call-audio")
    private var callPeer: MCPeerID?
    private var callAudio: CallAudio?
    private var ringtone: AVAudioPlayer?
    private var callTimer: Timer?

    override init() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "supernova.identity") ?? UUID().uuidString
        defaults.set(id, forKey: "supernova.identity")
        identityId = id
        let name = defaults.string(forKey: "supernova.name") ?? UIDevice.current.name
        let safeDisplay = String(name.prefix(24))
        displayName = safeDisplay
        let safeName = "\(safeDisplay)-\(id.prefix(4))"
        let peer = MCPeerID(displayName: safeName)
        myPeerID = peer
        dhPrivate = Keychain.loadOrCreatePrivateKey(account: "x25519")
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        if let data = UserDefaults.standard.data(forKey: "supernova.friends"),
           let decoded = try? JSONDecoder().decode([Friend].self, from: data) {
            friends = decoded
        }
        session.delegate = self
    }

    func start() {
        guard advertiser == nil else { return }
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["app": "Betelgeuse", "v": "1"], serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        status = "Ищу устройства рядом…"
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        advertiser = nil
        browser = nil
    }

    func setName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = String(trimmed.prefix(24))
        UserDefaults.standard.set(displayName, forKey: "supernova.name")
        // MCPeerID cannot be renamed in place; the next launch uses the new name.
        status = "Имя сохранено. Перезапустите приложение, чтобы оно появилось у других."
    }

    func invite(_ peer: NearbyPeer) {
        status = "Подключаюсь к \(peer.name)…"
        browser?.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 30)
    }

    func disconnect() {
        if call != nil { hangUp() }
        session.disconnect()
        connectedPeer = nil
        connectedName = nil
        connectedIdentityId = nil
        fingerprint = nil
        keys.removeAll()
        peerDh.removeAll()
        peerIdentity.removeAll()
        status = "Ищу устройства рядом…"
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let peer = connectedPeer, let key = keys[peer.displayName] else { return }
        let messageId = UUID().uuidString
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        guard let combined = try? LocalCrypto.seal(text: trimmed, key: key, from: identityId, to: peerIdentity[peer.displayName] ?? "", id: messageId, ts: ts) else {
            status = "Не удалось зашифровать сообщение"
            return
        }
        let envelope: [String: Any] = [
            "v": 1,
            "type": "message",
            "from": identityId,
            "to": peerIdentity[peer.displayName] ?? "",
            "id": messageId,
            "ts": ts,
            "body": combined.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            appendMessage(ChatMessage(text: trimmed, mine: true, at: Date()))
        } catch {
            status = "Ошибка отправки: \(error.localizedDescription)"
        }
    }

    private func sendHello(to peer: MCPeerID) {
        let hello: [String: Any] = [
            "v": 1,
            "type": "hello",
            "id": identityId,
            "name": displayName,
            "dh": dhPrivate.publicKey.rawRepresentation.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: hello) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    func startCall() {
        guard call == nil, let peer = connectedPeer, let identity = connectedIdentityId else { return }
        let callId = UUID().uuidString
        callPeer = peer
        call = ActiveCall(id: callId, peerIdentityId: identity, peerName: connectedName ?? "Собеседник",
                          outgoing: true, phase: .outgoing, startedAt: Date())
        sendCallSignal("offer", callId: callId)
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            guard let self, self.call?.phase == .outgoing else { return }
            self.sendCallSignal("cancel", callId: callId)
            self.endCallLocally()
        }
    }

    func acceptCall() {
        guard var current = call, current.phase == .incoming else { return }
        sendCallSignal("answer", callId: current.id)
        current.phase = .active
        current.startedAt = Date()
        call = current
        stopRingtone()
        startCallAudio()
    }

    func rejectCall() {
        guard let current = call else { return }
        sendCallSignal(current.phase == .incoming ? "reject" : "end", callId: current.id)
        endCallLocally()
    }

    func hangUp() {
        guard let current = call else { return }
        if current.phase != .incoming { sendCallSignal("end", callId: current.id) }
        endCallLocally()
    }

    func toggleMute() {
        guard var current = call else { return }
        current.muted.toggle()
        call = current
        callAudio?.isMuted = current.muted
    }

    func toggleSpeaker() {
        guard var current = call else { return }
        current.speaker.toggle()
        call = current
        callAudio?.setSpeaker(current.speaker)
    }

    private func sendCallSignal(_ action: String, callId: String) {
        guard let peer = callPeer else { return }
        let payload: [String: Any] = [
            "v": 1, "type": "call", "action": action, "callId": callId,
            "from": identityId,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func handleCallSignal(_ object: [String: Any], from peer: MCPeerID) {
        DispatchQueue.main.async { self.processCallSignal(object, from: peer) }
    }

    private func processCallSignal(_ object: [String: Any], from peer: MCPeerID) {
        guard let action = object["action"] as? String,
              let callId = object["callId"] as? String,
              let fromId = object["from"] as? String,
              fromId == peerIdentity[peer.displayName] else { return }
        switch action {
        case "offer":
            if call != nil {
                sendBusy(to: peer, callId: callId)
                return
            }
            callPeer = peer
            call = ActiveCall(id: callId, peerIdentityId: fromId,
                              peerName: friend(for: fromId)?.name ?? connectedName ?? peer.displayName,
                              outgoing: false, phase: .incoming, startedAt: Date())
            startRingtone()
            LocalNotifications.incomingCall(from: call?.peerName ?? "Betelgeuse")
            if autoAnswer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.acceptCall() }
            }
        case "answer":
            guard var current = call, current.id == callId, current.outgoing, current.phase == .outgoing else { return }
            current.phase = .active
            current.startedAt = Date()
            call = current
            callTimer?.invalidate()
            startCallAudio()
        case "reject", "busy", "end", "cancel":
            guard call?.id == callId else { return }
            endCallLocally()
        default:
            break
        }
    }

    private func sendBusy(to peer: MCPeerID, callId: String) {
        let payload: [String: Any] = ["v": 1, "type": "call", "action": "busy", "callId": callId, "from": identityId]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    private func startCallAudio() {
        guard !skipCallAudio else { return }
        stopRingtone()
        let audio = CallAudio()
        audio.onAudio = { [weak self] pcm in
            guard let self, let peer = self.callPeer, self.call?.phase == .active else { return }
            var packet = Data([0xA1])
            packet.append(pcm)
            try? self.session.send(packet, toPeers: [peer], with: .unreliable)
        }
        audio.onError = { [weak self] message in
            DispatchQueue.main.async { self?.callError = message }
        }
        audio.start()
        callAudio = audio
    }

    private func startRingtone() {
        guard ringtone == nil, let url = Bundle.main.url(forResource: "ring", withExtension: "wav") else { return }
        ringtone = try? AVAudioPlayer(contentsOf: url)
        ringtone?.numberOfLoops = -1
        ringtone?.volume = 0.7
        ringtone?.play()
    }

    private func stopRingtone() {
        ringtone?.stop()
        ringtone = nil
    }

    private func endCallLocally() {
        callTimer?.invalidate()
        callTimer = nil
        stopRingtone()
        callAudio?.stop()
        callAudio = nil
        call = nil
        callPeer = nil
    }

    private func appendMessage(_ message: ChatMessage) {
        DispatchQueue.main.async {
            self.messages.append(message)
            if !message.mine {
                self.unread += 1
                LocalNotifications.incomingMessage(from: self.connectedName ?? "Betelgeuse")
            }
        }
    }

    func clearUnread() {
        unread = 0
        LocalNotifications.clearBadge()
    }

    func isFriend(_ identityId: String?) -> Bool {
        guard let identityId else { return false }
        return friends.contains { $0.peerIdentityId == identityId }
    }

    func friend(for identityId: String?) -> Friend? {
        guard let identityId else { return nil }
        return friends.first { $0.peerIdentityId == identityId }
    }

    func addFriend(name: String) {
        guard let id = connectedIdentityId else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let index = friends.firstIndex(where: { $0.peerIdentityId == id }) {
            friends[index].name = clean
        } else {
            friends.append(Friend(peerIdentityId: id, name: String(clean.prefix(40)), addedAt: Date()))
        }
        saveFriends()
        if connectedName != nil { connectedName = clean }
    }

    func removeFriend(_ friend: Friend) {
        friends.removeAll { $0.peerIdentityId == friend.peerIdentityId }
        saveFriends()
        if connectedIdentityId == friend.peerIdentityId, let id = connectedIdentityId {
            connectedName = peerIdentity[id] ?? connectedName
        }
    }

    func persistFriends() { saveFriends() }

    private func saveFriends() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: "supernova.friends")
        }
    }

    private func handleHello(_ object: [String: Any], from peer: MCPeerID) {
        guard let id = object["id"] as? String,
              let name = object["name"] as? String,
              let dh64 = object["dh"] as? String,
              let dhData = Data(base64Encoded: dh64), dhData.count == 32 else { return }
        peerIdentity[peer.displayName] = id
        peerDh[peer.displayName] = dhData
        if let key = try? LocalCrypto.messageKey(privateKey: dhPrivate, peerPublicRaw: dhData) {
            keys[peer.displayName] = key
            let fp = LocalCrypto.fingerprint(keys: [dhPrivate.publicKey.rawRepresentation, dhData])
            DispatchQueue.main.async {
                self.connectedIdentityId = id
                self.connectedName = self.friend(for: id)?.name ?? name
                self.connectedPeer = peer
                self.fingerprint = fp
                self.status = "Соединено"
                if self.autoMessage && !self.autoSent {
                    self.autoSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.send("Привет! Это Бетельгейзе без сервера.")
                    }
                }
                if self.autoCall && self.call == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startCall() }
                }
            }
        }
    }

    private func handleMessage(_ object: [String: Any], from peer: MCPeerID) {
        guard let id = object["id"] as? String,
              let from = object["from"] as? String,
              let to = object["to"] as? String,
              let tsNumber = object["ts"] as? NSNumber,
              let body64 = object["body"] as? String,
              let combined = Data(base64Encoded: body64),
              to == identityId,
              let key = keys[peer.displayName],
              let peerId = peerIdentity[peer.displayName],
              from == peerId else { return }
        let ts = tsNumber.int64Value
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if abs(now - ts) > 5 * 60 * 1000 { return }
        if seen.contains(id) { return }
        guard let text = try? LocalCrypto.open(combined: combined, key: key, from: from, to: to, id: id, ts: ts) else { return }
        seen.insert(id)
        appendMessage(ChatMessage(text: text, mine: false, at: Date()))
    }
}

extension MeshService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            sendHello(to: peerID)
            DispatchQueue.main.async {
                self.connectedPeer = peerID
                self.connectedName = self.peerIdentity[peerID.displayName] ?? peerID.displayName
                self.status = "Соединено"
            }
        case .notConnected:
            DispatchQueue.main.async {
                if self.connectedPeer == peerID {
                    self.connectedPeer = nil
                    self.connectedName = nil
                    self.connectedIdentityId = nil
                    self.fingerprint = nil
                    self.status = "Соединение потеряно"
                }
                self.nearby.removeAll { $0.peerID == peerID }
                if self.callPeer == peerID { self.endCallLocally() }
            }
            keys[peerID.displayName] = nil
            peerDh[peerID.displayName] = nil
            peerIdentity[peerID.displayName] = nil
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if data.first == 0xA1 {
            guard call?.phase == .active, peerID == callPeer, callAudio != nil else { return }
            callAudio?.receive(data.dropFirst())
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "hello": handleHello(object, from: peerID)
        case "message": handleMessage(object, from: peerID)
        case "call": handleCallSignal(object, from: peerID)
        default: break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MeshService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension MeshService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard peerID != self.myPeerID else { return }
            if !self.nearby.contains(where: { $0.peerID == peerID }) {
                let name = peerID.displayName.components(separatedBy: "-").dropLast().joined(separator: "-")
                self.nearby.append(NearbyPeer(id: peerID.displayName, peerID: peerID, name: name.isEmpty ? peerID.displayName : name))
                if self.autoConnect && self.connectedName == nil && self.autoSent == false {
                    self.autoSent = true
                    self.invite(self.nearby.last!)
                }
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.nearby.removeAll { $0.peerID == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.status = "Поиск недоступен: \(error.localizedDescription)" }
    }
}

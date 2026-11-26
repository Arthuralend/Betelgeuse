import SwiftUI
import AVFoundation
import WebRTC

struct CallIceSettings {
    var urls = ""
    var username = ""
    var password = ""

    func servers() throws -> [RTCIceServer] {
        let entries = urls.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard entries.count <= 4, entries.allSatisfy({ value in
            value.utf8.count <= 512 && ["stun:", "stuns:", "turn:", "turns:"].contains { value.hasPrefix($0) }
        }) else { throw DirectError("Укажите до четырёх STUN/TURN URL через запятую") }
        return entries.map { value in
            if value.hasPrefix("turn:") || value.hasPrefix("turns:") {
                return RTCIceServer(urlStrings: [value], username: username, credential: password)
            }
            return RTCIceServer(urlStrings: [value])
        }
    }
}

final class RustCall: NSObject, ObservableObject, RTCPeerConnectionDelegate {
    enum Phase { case idle, outgoing, incoming, connecting, connected }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var video = false
    @Published private(set) var peer = ""
    @Published private(set) var muted = false
    @Published private(set) var cameraDisabled = false
    @Published private(set) var localVideo: RTCVideoTrack?
    @Published private(set) var remoteVideo: RTCVideoTrack?
    var sender: (([String: Any]) -> Bool)?

    private static let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    private var id = ""
    private var initiator = false
    private var iceSettings = CallIceSettings()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var camera: RTCCameraVideoCapturer?
    private var localICE: [RTCIceCandidate] = []
    private var remoteICE: [RTCIceCandidate] = []
    private var localDescriptionSent = false
    private var remoteDescriptionSet = false
    private var deadline: DispatchWorkItem?
    private var ringtone: AVAudioPlayer?
    @Published private(set) var speaker = false
    @Published private(set) var connectedAt: Date?

    private func startRinging() {
        guard let url = Bundle.main.url(forResource: "ring", withExtension: "wav") else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            ringtone = player
            player.play()
        } catch { /* The incoming screen remains available if audio is unavailable. */ }
    }
    private func stopRinging() { ringtone?.stop(); ringtone = nil }
    func toggleSpeaker() {
        guard phase == .connected else { return }
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .none : .speaker); speaker.toggle() } catch {}
    }

    var active: Bool { phase != .idle }

    func dial(_ peer: String, video: Bool, settings: CallIceSettings) {
        guard !active, !peer.isEmpty else { return }
        id = UUID().uuidString.lowercased(); self.peer = peer; self.video = video
        iceSettings = settings; initiator = true; phase = .outgoing; status = "Вызов…"
        if !transmit(["kind":"invite","video":video]) { finish("Не удалось отправить вызов"); return }
        scheduleTimeout(45)
    }

    func receive(_ event: [String: Any], settings: CallIceSettings) {
        guard let from = event["peer"] as? String, let callID = event["id"] as? String,
              let signal = event["signal"] as? [String: Any], let kind = signal["kind"] as? String else { return }
        if event["event"] as? String == "call_delivery" {
            guard active && id == callID && peer == from else { return }
            if kind == "ice" { return }
            if kind == "hangup" || kind == "reject" || kind == "busy" { return }
            finish(event["error"] as? String ?? "Сигнал не доставлен")
            return
        }
        if kind == "invite" {
            if active {
                if id != callID || peer != from {
                    _ = sender?(["op":"call_signal","peer":from,"id":callID,"signal":["kind":"busy"]])
                }
                return
            }
            peer = from; id = callID; video = signal["video"] as? Bool ?? false
            iceSettings = settings; initiator = false; phase = .incoming
            status = video ? "Входящий видеозвонок" : "Входящий аудиозвонок"
            startRinging()
            scheduleTimeout(45)
            return
        }
        guard active, callID == id, from == peer else { return }
        switch kind {
        case "accept" where phase == .outgoing && initiator:
            phase = .connecting; status = "Подключение…"; scheduleTimeout(60)
            setup { [weak self] ok in if ok { self?.makeSDP(offer: true) } }
        case "offer" where phase == .connecting && !initiator:
            if let sdp = signal["sdp"] as? String { applyRemote(sdp, type: .offer) }
        case "answer" where phase == .connecting && initiator:
            if let sdp = signal["sdp"] as? String { applyRemote(sdp, type: .answer) }
        case "ice":
            guard let text = signal["candidate"] as? String, let line = signal["line"] as? Int,
                  line >= 0 && line < 64 else { return }
            let candidate = RTCIceCandidate(sdp: text, sdpMLineIndex: Int32(line), sdpMid: signal["mid"] as? String)
            if remoteDescriptionSet { connection?.add(candidate) { _ in } }
            else if remoteICE.count < 128 { remoteICE.append(candidate) }
        case "reject": finish("Вызов отклонён")
        case "busy": finish("Собеседник занят")
        case "hangup": finish("Звонок завершён")
        default: break
        }
    }

    func answer() {
        guard phase == .incoming else { return }
        stopRinging()
        phase = .connecting; status = "Подключение…"; scheduleTimeout(60)
        setup { [weak self] ok in
            guard let self, ok else { return }
            if !self.transmit(["kind":"accept"]) { self.finish("Не удалось ответить") }
        }
    }

    func hangup() {
        guard active else { return }
        _ = transmit(["kind": phase == .incoming ? "reject" : "hangup"])
        finish("Звонок завершён")
    }

    func toggleMute() { muted.toggle(); audioTrack?.isEnabled = !muted }
    func toggleCamera() { cameraDisabled.toggle(); localVideo?.isEnabled = !cameraDisabled }

    private func transmit(_ signal: [String: Any]) -> Bool {
        sender?(["op":"call_signal","peer":peer,"id":id,"signal":signal]) ?? false
    }

    private func scheduleTimeout(_ seconds: Double) {
        deadline?.cancel()
        let expected = id
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.id == expected, self.phase != .connected else { return }
            _ = self.transmit(["kind":"hangup"])
            self.finish(self.phase == .connecting ? "Не удалось установить медиасоединение. Проверьте STUN/TURN." : "Время ожидания истекло")
        }
        deadline = timer; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func setup(_ completion: @escaping (Bool)->Void) {
        let expected = id, withVideo = video
        Task { @MainActor [weak self] in
            guard let self else { return }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            let cameraAllowed = withVideo ? await AVCaptureDevice.requestAccess(for: .video) : true
            guard self.id == expected && self.phase == .connecting else { return }
            guard microphone && cameraAllowed else {
                _ = self.transmit(["kind":"hangup"]); self.finish("Нет разрешения на микрофон или камеру"); return
            }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playAndRecord, mode: withVideo ? .videoChat : .voiceChat,
                                      options:[.allowBluetooth])
                self.speaker = withVideo
                try audio.setActive(true)
                if withVideo { try audio.overrideOutputAudioPort(.speaker) }
                let config = RTCConfiguration()
                config.sdpSemantics = .unifiedPlan
                config.iceServers = try self.iceSettings.servers()
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                    throw DirectError("Не удалось создать WebRTC")
                }
                self.connection = pc
                let source = Self.factory.audioSource(with: constraints)
                let track = Self.factory.audioTrack(with: source, trackId: "audio")
                self.audioTrack = track
                _ = pc.add(track, streamIds: ["betelgeuse"])
                if withVideo {
                    let source = Self.factory.videoSource()
                    let capturer = RTCCameraVideoCapturer(delegate: source)
                    self.camera = capturer
                    let devices = RTCCameraVideoCapturer.captureDevices()
                    guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
                        throw DirectError("Камера недоступна")
                    }
                    let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                    guard let format = formats.filter({ f in
                        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                        return d.width <= 1280 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 24 && $0.minFrameRate <= 24 }
                    }).max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) ??
                        formats.first else { throw DirectError("Формат камеры недоступен") }
                    let track = Self.factory.videoTrack(with: source, trackId:"video")
                    self.localVideo = track
                    _ = pc.add(track, streamIds: ["betelgeuse"])
                    let fps = min(24, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24))
                    capturer.startCapture(with: device, format: format, fps: max(fps, 1)) { [weak self] error in
                        if let error { DispatchQueue.main.async { self?.fail(expected, error.localizedDescription) } }
                    }
                }
                completion(true)
            } catch { self.fail(expected,error.localizedDescription); completion(false) }
        }
    }

    private func makeSDP(offer: Bool) {
        guard let pc = connection else { return }
        let expected = id
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let created: (RTCSessionDescription?, Error?) -> Void = { [weak self, weak pc] description, error in
            DispatchQueue.main.async {
                guard let self, let pc, self.id == expected, self.connection === pc else { return }
                guard let description else { self.fail(expected,error?.localizedDescription ?? "Ошибка SDP"); return }
                pc.setLocalDescription(description) { [weak self, weak pc] error in
                    DispatchQueue.main.async {
                        guard let self, let pc, self.id == expected, self.connection === pc else { return }
                        if let error { self.fail(expected,error.localizedDescription); return }
                        guard self.transmit(["kind":offer ? "offer" : "answer","sdp":description.sdp]) else {
                            self.fail(expected,"SDP не отправлено"); return
                        }
                        self.localDescriptionSent = true
                        for candidate in self.localICE { self.sendCandidate(candidate) }
                        self.localICE.removeAll()
                    }
                }
            }
        }
        if offer { pc.offer(for: constraints, completionHandler: created) }
        else { pc.answer(for: constraints, completionHandler: created) }
    }

    private func applyRemote(_ sdp: String, type: RTCSdpType) {
        guard let pc = connection, !remoteDescriptionSet else { return }
        let expected = id
        pc.setRemoteDescription(RTCSessionDescription(type:type,sdp:sdp)) { [weak self, weak pc] error in
            DispatchQueue.main.async {
                guard let self, let pc, self.id == expected, self.connection === pc else { return }
                if let error { self.fail(expected,error.localizedDescription); return }
                self.remoteDescriptionSet = true
                for candidate in self.remoteICE { pc.add(candidate) { _ in } }
                self.remoteICE.removeAll()
                if type == .offer { self.makeSDP(offer:false) }
            }
        }
    }

    private func sendCandidate(_ candidate: RTCIceCandidate) {
        _ = transmit(["kind":"ice","candidate":candidate.sdp,
                      "mid":candidate.sdpMid as Any? ?? NSNull(),"line":Int(candidate.sdpMLineIndex)])
    }

    private func fail(_ expected: String, _ reason: String) {
        guard id == expected else { return }
        _ = transmit(["kind":"hangup"]); finish(reason)
    }

    private func finish(_ reason: String) {
        stopRinging(); connectedAt = nil; speaker = false
        deadline?.cancel(); deadline = nil
        let old = connection; connection = nil; old?.close()
        camera?.stopCapture(); camera = nil
        audioTrack?.isEnabled = false; audioTrack = nil
        localVideo?.isEnabled = false; localVideo = nil; remoteVideo = nil
        localICE.removeAll(); remoteICE.removeAll()
        localDescriptionSent = false; remoteDescriptionSet = false
        muted = false; cameraDisabled = false
        phase = .idle; status = reason; peer = ""; id = ""
        try? AVAudioSession.sharedInstance().setActive(false, options:[.notifyOthersOnDeactivation])
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self, weak pc] in
            guard let self, let pc, self.connection === pc else { return }
            if self.localDescriptionSent { self.sendCandidate(candidate) }
            else if self.localICE.count < 128 { self.localICE.append(candidate) }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self, weak pc] in
            guard let self, let pc, self.connection === pc else { return }
            switch newState {
            case .connected, .completed:
                self.deadline?.cancel(); self.phase = .connected; self.status = "Соединение установлено"
                if self.connectedAt == nil { self.connectedAt = Date() }
            case .checking: self.status = "Поиск голосового маршрута…"
            case .failed: self.fail(self.id,"WebRTC: соединение не установлено. Проверьте ICE/TURN.")
            case .disconnected:
                self.phase = .connecting; self.status = "Восстановление соединения…"; self.scheduleTimeout(30)
            default: break
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        DispatchQueue.main.async { [weak self, weak pc] in
            guard let self, let pc, self.connection === pc else { return }
            if let track = rtpReceiver.track as? RTCVideoTrack { self.remoteVideo = track }
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DispatchQueue.main.async { [weak self, weak pc] in
            guard let self, let pc, self.connection === pc else { return }
            if let track = stream.videoTracks.first { self.remoteVideo = track }
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

struct RustVideo: UIViewRepresentable {
    let track: RTCVideoTrack
    final class Coordinator {
        var current: RTCVideoTrack?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view=RTCMTLVideoView(frame:.zero); view.videoContentMode = .scaleAspectFit; return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.current !== track {
            context.coordinator.current?.remove(view)
            track.add(view); context.coordinator.current = track
        }
    }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) { coordinator.current?.remove(view) }
}


struct RustCallScreen: View {
    @ObservedObject var call: RustCall
    let name: String
    private var incoming: Bool { call.phase == .incoming }
    private var connected: Bool { call.phase == .connected }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.09, blue: 0.12), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if let track = call.remoteVideo { RustVideo(track: track).ignoresSafeArea() }
            VStack(spacing: 18) {
                Text("БЕТЕЛЬГЕЙЗЕ").font(.caption.weight(.semibold)).tracking(4).foregroundStyle(.orange)
                Spacer(minLength: 12)
                if call.remoteVideo == nil {
                    ZStack {
                        Circle().fill(.orange.opacity(0.13)).frame(width: 140, height: 140)
                        Circle().strokeBorder(.orange.opacity(0.5), lineWidth: 2).frame(width: 114, height: 114)
                        Image(systemName: call.video ? "video.fill" : "person.crop.circle.fill").font(.system(size: 55)).foregroundStyle(.orange)
                    }
                }
                Text(name).font(.largeTitle.bold()).multilineTextAlignment(.center).lineLimit(2)
                Text(call.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if connected, let start = call.connectedAt { Text(start, style: .timer).monospacedDigit() }
                if let track = call.localVideo { RustVideo(track: track).frame(width: 110, height: 150).clipShape(RoundedRectangle(cornerRadius: 16)) }
                Spacer(minLength: 12)
                if incoming {
                    HStack(spacing: 48) {
                        control("phone.down.fill", "Отклонить", .red, call.hangup)
                        control("phone.fill", "Ответить", .green, call.answer)
                    }
                } else {
                    if call.phase == .connected || call.phase == .connecting {
                        HStack(spacing: 20) {
                            control(call.muted ? "mic.slash.fill" : "mic.fill", "Микрофон", .gray, call.toggleMute)
                            if connected { control(call.speaker ? "speaker.wave.2.fill" : "speaker.fill", "Динамик", .gray, call.toggleSpeaker) }
                            if call.video { control(call.cameraDisabled ? "video.slash.fill" : "video.fill", "Камера", .gray, call.toggleCamera) }
                        }
                    }
                    control("phone.down.fill", "Завершить", .red, call.hangup)
                }
            }.padding(28).foregroundStyle(.white)
        }.preferredColorScheme(.dark).interactiveDismissDisabled()
    }
    private func control(_ icon: String, _ title: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 27, weight: .semibold)).frame(width: 66, height: 66).background(color, in: Circle())
                Text(title).font(.caption)
            }.foregroundStyle(.white)
        }.buttonStyle(.plain)
    }
}

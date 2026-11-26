import Foundation
import AVFoundation

/// PCM audio for local calls. 16 kHz mono signed 16-bit little-endian over
/// MultipeerConnectivity's unreliable data channel.
final class CallAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var converter: AVAudioConverter?
    private var running = false
    private var stopped = false
    private var tapInstalled = false
    private var playerAttached = false
    private let stateLock = NSLock()
    private var muted = false
    var isMuted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return muted }
        set { stateLock.lock(); muted = newValue; stateLock.unlock() }
    }
    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.onError?("Нет доступа к микрофону") }
                return
            }
            DispatchQueue.main.async { self.startEngine() }
        }
    }

    private func startEngine() {
        guard !running, !stopped, !tapInstalled, !playerAttached else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
                  let conversion = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "SupernovaAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            converter = conversion
            engine.attach(player)
            playerAttached = true
            // Apple's mixer expects a standard floating-point PCM stream.
            // Keep Int16 only as the interoperable on-wire representation.
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.capture(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            player.play()
            stateLock.lock(); running = true; stateLock.unlock()
        } catch {
            stop()
            onError?(error.localizedDescription)
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock(); let enabled = running && !muted; stateLock.unlock()
        guard enabled, buffer.frameLength > 0, buffer.format.sampleRate > 0,
              let converter, buffer.format == converter.inputFormat, let onAudio else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 8
        guard capacity > 0, capacity <= 16_384,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        if !data.isEmpty { onAudio(data) }
    }

    func receive(_ pcm: Data) {
        guard running, pcm.count >= 2, pcm.count <= 32_768, pcm.count % 2 == 0 else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let destination = buffer.floatChannelData?[0] else { return }
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<Int(frames) {
                let word = UInt16(raw[i * 2]) | (UInt16(raw[i * 2 + 1]) << 8)
                destination[i] = Float(Int16(bitPattern: word)) / 32768.0
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func setSpeaker(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stateLock.lock(); running = false; stateLock.unlock()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if playerAttached { player.stop() }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

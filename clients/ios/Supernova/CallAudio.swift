import Foundation
import AVFoundation

/// PCM audio for local calls. 16 kHz mono signed 16-bit little-endian over
/// MultipeerConnectivity's unreliable data channel.
final class CallAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var running = false
    private var stopped = false
    private var tapInstalled = false
    var isMuted = false
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
        guard !running, !stopped else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw NSError(domain: "SupernovaAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: targetFormat)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            player.play()
            running = true
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard running, !isMuted, let converter, let onAudio else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
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
        guard running, pcm.count >= 2 else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let destination = buffer.int16ChannelData?[0] else { return }
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = destination.withMemoryRebound(to: UInt8.self, capacity: pcm.count) { dest in
                memcpy(dest, base, pcm.count)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func setSpeaker(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func stop() {
        stopped = true
        running = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

import AVFoundation
import Foundation

final class Ear: @unchecked Sendable {
    var onLevel: ((Float) -> Void)?
    var onUtterance: (([Float]) -> Void)?
    var onSilence: (() -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var tapping = false
    private let lock = NSLock()
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var ambient: [Float] = []
    private var ambientSamples = 0
    private var speechPeak: Float = 0
    private var speech = false
    private var quiet: Int = 0
    private var speechCount: Int = 0
    private var waited: Int = 0
    private let rate: Double = 16_000

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { ok in
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    func start() throws {
        stop(send: false)
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardware, to: target) else {
            throw EarError.noFormat
        }
        self.converter = converter
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        ambient.removeAll(keepingCapacity: true)
        ambientSamples = 0
        speechPeak = 0
        speech = false
        quiet = 0
        speechCount = 0
        waited = 0
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapping = true
        engine.prepare()
        try engine.start()
    }

    @discardableResult
    func stop(send: Bool) -> Bool {
        detach()
        var utterance: [Float] = []
        lock.lock()
        if send, speechCount > Int(rate * 0.3) {
            utterance = samples
        }
        samples.removeAll(keepingCapacity: true)
        speech = false
        speechCount = 0
        lock.unlock()
        if !utterance.isEmpty {
            onUtterance?(utterance)
            return true
        }
        return false
    }

    private func detach() {
        if tapping {
            engine.inputNode.removeTap(onBus: 0)
            tapping = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = rate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }
        var error: NSError?
        var used = false
        converter.convert(to: converted, error: &error) { _, status in
            if used {
                status.pointee = .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return buffer
        }
        guard let channel = converted.floatChannelData else { return }
        let count = Int(converted.frameLength)
        if count == 0 { return }
        let frame = Array(UnsafeBufferPointer(start: channel[0], count: count))
        let energy = rms(frame)

        var finished: [Float]?
        var timedOut = false
        lock.lock()
        let prerollCap = Int(rate * 0.25)
        if !speech {
            preroll.append(contentsOf: frame)
            if preroll.count > prerollCap {
                preroll.removeFirst(preroll.count - prerollCap)
            }
            if ambientSamples < Int(rate * 0.2) {
                ambient.append(energy)
                ambientSamples += count
            } else {
                let noise = median(ambient)
                let threshold = max(noise * 2.4 + 0.003, 0.006)
                waited += count
                if energy >= threshold {
                    speech = true
                    speechPeak = energy
                    quiet = 0
                    samples.append(contentsOf: preroll)
                    speechCount = samples.count
                } else if waited > Int(rate * 6) {
                    timedOut = true
                }
            }
        } else {
            samples.append(contentsOf: frame)
            speechCount += count
            speechPeak = max(speechPeak, energy)
            let noise = median(ambient)
            let floor = noise * 1.45 + 0.0015
            let endLine = min(max(floor, speechPeak * 0.28), speechPeak * 0.5)
            if energy < endLine {
                quiet += count
            } else {
                quiet = 0
            }
            // A short pause ends the phrase. The old 1.15s gate, plus a bad
            // noise estimate, kept the mic open as if the user were still talking.
            if speechCount > Int(rate * 0.28), quiet > Int(rate * 0.55) || speechCount > Int(rate * 20) {
                finished = samples
                samples.removeAll(keepingCapacity: true)
                speech = false
                speechPeak = 0
            }
        }
        lock.unlock()

        onLevel?(min(1, energy * 8))
        if let finished {
            DispatchQueue.main.async { [weak self] in
                self?.detach()
                self?.onUtterance?(finished)
            }
        } else if timedOut {
            DispatchQueue.main.async { [weak self] in
                self?.detach()
                self?.onSilence?()
            }
        }
    }

    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for value in frame { sum += value * value }
        return sqrt(sum / Float(frame.count))
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

enum EarError: Error {
    case noFormat
}

final class Mouth: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    private var timer: Timer?
    private var pulseStart = Date()

    func play(_ data: Data) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.isMeteringEnabled = true
        player.prepareToPlay()
        self.player = player
        player.play()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, player.isPlaying else { return }
                player.updateMeters()
                let db = player.averagePower(forChannel: 0)
                let level = min(1, max(0, (db + 45) / 45))
                self.onLevel?(level)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func speak(text: String, voiceID: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.delegate = self
        synth.speak(utterance)
        pulseStart = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(self.pulseStart)
                let level = Float(0.22 + 0.18 * sin(t * 7))
                self.onLevel?(level)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.onFinish?()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async { [weak self] in
            self?.onFinish?()
        }
    }
}

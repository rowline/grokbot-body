import AVFoundation
import Foundation
import Speech

/// On-device ear and mouth. The bound Grok Bot is the brain.
@MainActor
final class EarMouth: NSObject, SFSpeechRecognizerDelegate, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    var onUtterance: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onListening: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var alwaysListen = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var speakingContinuation: CheckedContinuation<Void, Never>?
    private var lastSent = ""
    private var lastPartial = ""
    private var endTalkFlush: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        recognizer?.delegate = self
    }

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return speech && mic
    }

    func startListening() {
        stopListening()
        guard let recognizer, recognizer.isAvailable else {
            onError?("听写不可用")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true)
        } catch {
            onError?("麦克风打不开")
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString {
                    self.lastPartial = text
                    self.onPartial?(text)
                    if result?.isFinal == true {
                        self.commit(text)
                        if self.alwaysListen {
                            self.restartListeningSoon()
                        } else {
                            self.stopListening()
                        }
                    }
                } else if error != nil {
                    if self.alwaysListen {
                        self.restartListeningSoon()
                    } else {
                        self.stopListening()
                    }
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            onListening?(true)
        } catch {
            stopListening()
        }
    }

    func stopListening() {
        endTalkFlush?.cancel()
        endTalkFlush = nil
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        lastPartial = ""
        onListening?(false)
    }

    func speak(_ text: String, audio: Data? = nil, apiKey: String? = nil, voiceId: String = "eve") async {
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        finishSpeak()

        if let audio, !audio.isEmpty, await playGrokAudio(audio) {
            if alwaysListen { startListening() }
            return
        }
        if let apiKey, !apiKey.isEmpty,
           let grok = await fetchGrokSpeech(text: text, apiKey: apiKey, voiceId: voiceId),
           await playGrokAudio(grok) {
            if alwaysListen { startListening() }
            return
        }
        await speakApple(text)
        if alwaysListen { startListening() }
    }

    private func fetchGrokSpeech(text: String, apiKey: String, voiceId: String) async -> Data? {
        guard let url = URL(string: "https://api.x.ai/v1/tts") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let clipped = String(text.prefix(1200))
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": clipped,
            "voice_id": voiceId,
            "language": "zh",
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24000,
                "bit_rate": 128000,
            ],
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, data.count > 64 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func speakApple(_ text: String) async {
        prepareAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { continuation in
            speakingContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    private func playGrokAudio(_ data: Data) async -> Bool {
        prepareAudioSession()
        var started = false
        await withCheckedContinuation { continuation in
            speakingContinuation = continuation
            do {
                let next = try AVAudioPlayer(data: data)
                next.delegate = self
                player = next
                started = next.play()
                if !started { finishSpeak() }
            } catch {
                finishSpeak()
            }
        }
        return started
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try? session.setActive(true)
    }

    private func finishSpeak() {
        let pending = speakingContinuation
        speakingContinuation = nil
        pending?.resume()
    }

    func beginTalk() {
        lastSent = ""
        lastPartial = ""
        startListening()
    }

    func endTalk() {
        request?.endAudio()
        endTalkFlush?.cancel()
        endTalkFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.alwaysListen else { return }
            self.commit(self.lastPartial)
            self.stopListening()
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastSent else { return }
        lastSent = trimmed
        onUtterance?(trimmed)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSpeak()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSpeak()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishSpeak()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishSpeak()
    }

    private func restartListeningSoon() {
        stopListening()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            startListening()
        }
    }
}

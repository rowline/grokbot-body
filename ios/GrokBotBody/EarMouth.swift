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
    var alwaysListen = false {
        didSet {
            if !alwaysListen { restartToken += 1 }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var speakingContinuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?
    private var lastSent = ""
    private var lastPartial = ""
    private var lastSpoken = ""
    private var lastSpokenAt = Date.distantPast
    private var endTalkFlush: Task<Void, Never>?
    private var listenGeneration = 0
    private var endingTalk = false
    private var speakTimeout: Task<Void, Never>?
    private var restartToken = 0
    private var tapInstalled = false

    override init() {
        super.init()
        synthesizer.delegate = self
        recognizer?.delegate = self
    }

    deinit {
        synthesizer.delegate = nil
        player?.delegate = nil
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
        lastSent = ""
        guard let recognizer, recognizer.isAvailable else {
            onError?("听写不可用")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
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
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("麦克风打不开")
            return
        }

        listenGeneration += 1
        let generation = listenGeneration
        do {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.listenGeneration == generation else { return }
                    if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                        self.lastPartial = text
                        self.onPartial?(text)
                        if result?.isFinal == true {
                            self.commit(text)
                            self.finishListenSession(generation: generation)
                        }
                    } else if error != nil {
                        if self.endingTalk {
                            return
                        }
                        if !self.lastPartial.isEmpty {
                            self.commit(self.lastPartial)
                        }
                        self.finishListenSession(generation: generation)
                    }
                }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            onListening?(true)
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            if engine.isRunning { engine.stop() }
            recognitionTask?.cancel()
            recognitionTask = nil
            onError?("麦克风打不开")
        }
    }

    func stopListening() {
        listenGeneration += 1
        endingTalk = false
        endTalkFlush?.cancel()
        endTalkFlush = nil
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }
        tapInstalled = false
        engine = nil
        lastPartial = ""
        onListening?(false)
    }

    func speak(
        _ text: String,
        audio: Data? = nil,
        apiKey: String? = nil,
        voiceId: String = "eve",
        remember: Bool = true
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        if remember, trimmed == lastSpoken, now.timeIntervalSince(lastSpokenAt) < 12 {
            return
        }
        if remember {
            lastSpoken = trimmed
            lastSpokenAt = now
        }

        restartToken += 1
        stopListening()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        finishSpeak()

        if let audio, !audio.isEmpty, await playGrokAudio(audio) {
            if alwaysListen { startListening() }
            return
        }
        if let apiKey, !apiKey.isEmpty,
           let grok = await fetchGrokSpeech(text: trimmed, apiKey: apiKey, voiceId: voiceId),
           await playGrokAudio(grok) {
            if alwaysListen { startListening() }
            return
        }
        await speakApple(trimmed)
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

    func previewAppleVoice() async {
        let resume = alwaysListen
        stopListening()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        finishSpeak()
        await speakApple("拍好了。下一句写在对话框。")
        if resume { startListening() }
    }

    private func speakApple(_ text: String) async {
        prepareAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        let voice = Self.resolveAppleVoice(CloudConfig.appleVoiceId)
        utterance.voice = voice
        if voice?.quality == .premium || voice?.quality == .enhanced {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        }
        utterance.pitchMultiplier = 1.02

        await withCheckedContinuation { continuation in
            currentUtterance = utterance
            speakingContinuation = continuation
            synthesizer.speak(utterance)
            armSpeakTimeout()
        }
    }

    struct AppleVoiceChoice: Identifiable, Hashable {
        var id: String { identifier }
        let identifier: String
        let label: String
        let quality: AVSpeechSynthesisVoiceQuality
        let isCompact: Bool
    }

    static func appleVoiceChoices() -> [AppleVoiceChoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("zh") }
            .sorted { rank($0) > rank($1) }
            .map { voice in
                AppleVoiceChoice(
                    identifier: voice.identifier,
                    label: displayLabel(voice),
                    quality: voice.quality,
                    isCompact: voice.quality == .default
                )
            }
    }

    static func resolveAppleVoice(_ identifier: String) -> AVSpeechSynthesisVoice? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let picked = AVSpeechSynthesisVoice(identifier: trimmed) {
            return picked
        }
        let chinese = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("zh") }
        let mainland = chinese.filter { $0.language.lowercased().hasPrefix("zh-cn") }
        let pool = mainland.isEmpty ? chinese : mainland
        return pool.max { rank($0) < rank($1) }
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    static func usingCompactAppleVoice(_ identifier: String) -> Bool {
        resolveAppleVoice(identifier)?.quality == .default
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 400
        case .enhanced: score += 300
        default: score += 100
        }
        if voice.voiceTraits.contains(.isPersonalVoice) { score += 500 }
        let id = voice.identifier.lowercased()
        if id.contains("siri") { score += 40 }
        if voice.language.lowercased().hasPrefix("zh-cn") { score += 10 }
        return score
    }

    private static func displayLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.voiceTraits.contains(.isPersonalVoice) {
            return "个人声音"
        }
        let name = nickname(voice.name)
        let quality: String
        switch voice.quality {
        case .premium: quality = "高级"
        case .enhanced: quality = "增强"
        default: quality = "压缩"
        }
        let region: String
        let lang = voice.language.lowercased()
        if lang.hasPrefix("zh-hk") {
            region = "粤语"
        } else if lang.hasPrefix("zh-tw") {
            region = "台湾"
        } else {
            region = ""
        }
        if region.isEmpty {
            return "\(name) · \(quality)"
        }
        return "\(name) · \(region) · \(quality)"
    }

    private static func nickname(_ name: String) -> String {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        let map: [String: String] = [
            "ting-ting": "婷婷",
            "tingting": "婷婷",
            "yu-shu": "雨舒",
            "yushu": "雨舒",
            "li-mu": "力穆",
            "limu": "力穆",
            "mei-jia": "美嘉",
            "meijia": "美嘉",
            "sin-ji": "善怡",
            "sinji": "善怡",
        ]
        return map[key] ?? name
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
                if !started {
                    player = nil
                    finishSpeak()
                } else {
                    armSpeakTimeout()
                }
            } catch {
                player = nil
                finishSpeak()
            }
        }
        return started
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func finishSpeak() {
        speakTimeout?.cancel()
        speakTimeout = nil
        let pending = speakingContinuation
        speakingContinuation = nil
        pending?.resume()
    }

    private func armSpeakTimeout() {
        speakTimeout?.cancel()
        speakTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(28))
            await self?.finishSpeak()
        }
    }

    func beginTalk() {
        lastSent = ""
        lastPartial = ""
        startListening()
    }

    func endTalk() {
        endingTalk = true
        request?.endAudio()
        endTalkFlush?.cancel()
        endTalkFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !self.alwaysListen else { return }
            self.commit(self.lastPartial)
            self.endingTalk = false
            self.stopListening()
        }
    }

    private func finishListenSession(generation: Int) {
        guard listenGeneration == generation else { return }
        if alwaysListen {
            restartListeningSoon()
        } else {
            endingTalk = false
            stopListening()
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastSent else { return }
        lastSent = trimmed
        onUtterance?(trimmed)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        finishSpeak()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        finishSpeak()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        finishSpeak()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        self.player = nil
        finishSpeak()
    }

    private func restartListeningSoon() {
        guard alwaysListen else { return }
        restartToken += 1
        let token = restartToken
        stopListening()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.alwaysListen, self.restartToken == token else { return }
            guard self.speakingContinuation == nil, self.player == nil, self.engine == nil else { return }
            self.startListening()
        }
    }
}

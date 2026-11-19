import AVFoundation
import NaturalLanguage
import Observation

@MainActor @Observable final class Speaker {
    private(set) var lastError: String?
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let stretch = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var token = 0
    @ObservationIgnored private nonisolated(unsafe) var configObserver: NSObjectProtocol?

    init() {
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers) }
        catch { lastError = error.localizedDescription }
        #endif
        engine.attach(player)
        engine.attach(stretch)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.format = nil
                    self?.player.stop()
                }
            }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func say(_ text: String, language: String? = nil, slow: Bool = false) {
        guard !text.isEmpty else { return }
        stop()
        token += 1
        let mine = token
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(for: language ?? Self.language(of: text))
        u.rate = slow ? 0.42 : AVSpeechUtteranceDefaultSpeechRate
        stretch.rate = slow ? 0.5 : 1
        synth.write(u) { [weak self] buffer in
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.token, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0,
                      let floats = self.toFloat(pcm) else { return }
                do {
                    try self.connect(floats.format)
                    self.player.scheduleBuffer(floats)
                    if !self.player.isPlaying { self.player.play() }
                    self.lastError = nil
                } catch { self.lastError = error.localizedDescription }
            }
        }
    }

    func stop() {
        token += 1
        synth.stopSpeaking(at: .immediate)
        player.stop()
    }

    static func language(of text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue ?? "fr"
    }

    static func resolveSpeech(front: String, answer: String, deckLanguage: String?) -> (text: String, language: String) {
        let target = deckLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target.isEmpty || target.lowercased().hasPrefix("fr") {
            let text = CardParts.lang(front) != .english ? front
                : CardParts.lang(answer) == .french ? answer : front
            return (text, target.isEmpty ? "fr-FR" : target)
        }
        let base = target.split(separator: "-").first.map { String($0).lowercased() } ?? target.lowercased()
        let frontLang = detectLanguageCode(front)
        let answerLang = detectLanguageCode(answer)
        if frontLang == base { return (front, target) }
        if answerLang == base { return (answer, target) }
        return (front, target)
    }

    private static func detectLanguageCode(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let raw = r.dominantLanguage?.rawValue else { return nil }
        return raw.split(separator: "-").first.map { String($0).lowercased() } ?? raw.lowercased()
    }

    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language) { return exact }
        if let base = language.split(separator: "-").first,
           let fallback = AVSpeechSynthesisVoice(language: String(base)) { return fallback }
        return AVSpeechSynthesisVoice(language: "fr")
    }

    private func connect(_ f: AVAudioFormat) throws {
        if format != f || !engine.isRunning {
            engine.stop()
            engine.connect(player, to: stretch, format: f)
            engine.connect(stretch, to: engine.mainMixerNode, format: f)
            format = f
        }
        if !engine.isRunning { try engine.start() }
    }

    private func toFloat(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if b.format.commonFormat == .pcmFormatFloat32 && !b.format.isInterleaved { return b }
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate,
                                    channels: b.format.channelCount, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength),
              let conv = AVAudioConverter(from: b.format, to: f) else { return nil }
        do { try conv.convert(to: out, from: b); return out }
        catch { lastError = error.localizedDescription; return nil }
    }
}

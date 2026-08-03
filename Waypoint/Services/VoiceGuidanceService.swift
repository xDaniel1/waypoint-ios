import AVFoundation
import Observation

/// Speaks navigation instructions aloud using the on-device speech synthesizer. This is real
/// spoken turn-by-turn — AVSpeechSynthesizer is a public API, not something Apple restricts to
/// its own Maps app; it just hadn't been wired up yet.
@Observable
@MainActor
final class VoiceGuidanceService {
    var isMuted = false {
        didSet {
            if isMuted { synthesizer.stopSpeaking(at: .immediate) }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        guard !isMuted else { return }
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        // `Locale.current.identifier` is underscore-separated ("en_US") and doesn't reliably
        // match a voice; `currentLanguageCode()` returns the properly formatted BCP-47 tag
        // ("en-US") for the device's active speech language.
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}

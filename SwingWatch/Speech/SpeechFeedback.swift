import AVFoundation

/// 스윙 직후 짧은 한국어 음성 안내.
/// 폰을 삼각대에 두고 치는 상황에서 화면을 안 봐도 결과를 알 수 있게 한다.
final class SpeechFeedback {

    private let synthesizer = AVSpeechSynthesizer()
    var isEnabled = true

    func speak(_ text: String) {
        guard isEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        synthesizer.speak(utterance)
    }
}

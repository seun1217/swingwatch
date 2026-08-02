import Foundation

/// 저장되는 스윙 기록(피드백 + 지표 + 세션 영상 안의 구간).
struct SwingRecord: Codable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var feedback: SwingFeedback
    var metrics: SwingMetrics
    var videoFileName: String?          // 세션 영상 파일 이름 (SessionVideos/ 안)
    var clipStart: TimeInterval?        // 세션 영상 내 스윙 시작 오프셋(초)
    var clipEnd: TimeInterval?

    var videoURL: URL? {
        guard let videoFileName else { return nil }
        return SessionRecorder.videosDirectory.appendingPathComponent(videoFileName)
    }
}

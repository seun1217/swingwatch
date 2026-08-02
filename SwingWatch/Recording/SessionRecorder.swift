import AVFoundation
import CoreMedia
import Foundation

/// 세션 전체를 하나의 .mov 파일로 기록한다.
/// 스윙별 클립은 별도 파일이 아니라 이 파일 안의 시간 오프셋(초)으로 참조한다.
/// 모든 메서드는 내부 락으로 보호되어 어느 큐에서든 호출할 수 있다.
final class SessionRecorder {

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private var fileName: String?

    static var videosDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var currentFileName: String? {
        lock.lock(); defer { lock.unlock() }
        return fileName
    }

    func start(fileName name: String) {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil else { return }
        let url = Self.videosDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        guard let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        writer = newWriter
        input = nil
        startTime = nil
        fileName = name
    }

    /// 녹화 중이 아니면 그냥 무시된다. 카메라 videoQueue에서 매 프레임 호출.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let writer else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if input == nil {
            // 첫 프레임에서 실제 크기를 보고 인코더를 구성한다.
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
            ]
            let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            newInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(newInput) else { resetLocked(); return }
            writer.add(newInput)
            guard writer.startWriting() else { resetLocked(); return }
            writer.startSession(atSourceTime: pts)
            input = newInput
            startTime = pts
        }

        guard writer.status == .writing, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// 세션 영상 안에서 주어진 카메라 버퍼 시각(초)이 갖는 오프셋(초).
    func offset(of bufferTime: TimeInterval) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let startTime else { return nil }
        return bufferTime - CMTimeGetSeconds(startTime)
    }

    func finish(completion: @escaping (URL?) -> Void) {
        lock.lock()
        let writer = self.writer
        let input = self.input
        resetLocked()
        lock.unlock()

        guard let writer else {
            completion(nil)
            return
        }
        guard writer.status == .writing, let input else {
            // 프레임이 한 장도 안 들어와 시작조차 못 한 경우
            try? FileManager.default.removeItem(at: writer.outputURL)
            completion(nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? writer.outputURL : nil)
        }
    }

    /// lock을 쥔 상태에서만 호출할 것.
    private func resetLocked() {
        writer = nil
        input = nil
        startTime = nil
        fileName = nil
    }
}

import AVFoundation
import Combine
import CoreMedia
import Foundation
import UIKit

/// 카메라 → 포즈 추정 → 스윙 감지 → 분석 → 피드백(화면/음성/워치/저장)
/// 전체 파이프라인을 묶는 최상위 객체.
///
/// 스레드 규칙:
/// - @Published 상태는 메인 큐에서만 갱신
/// - 포즈 추정과 스윙 감지는 poseQueue(직렬)에서만
/// - 녹화 append는 카메라 videoQueue에서 (SessionRecorder는 내부 락으로 보호)
final class SessionCoordinator: ObservableObject {

    // MARK: - UI 상태

    @Published private(set) var isSessionActive = false
    @Published private(set) var phase: SwingPhase = .waiting
    @Published private(set) var swingCount = 0
    @Published private(set) var latestFeedback: SwingFeedback?
    @Published private(set) var latestPose: PoseFrame?
    @Published private(set) var showFeedbackBanner = false
    @Published var isRecordingEnabled = true
    @Published var isVoiceEnabled = true {
        didSet { speech.isEnabled = isVoiceEnabled }
    }

    let camera = CameraManager()
    let store = SwingStore()
    let connectivity = PhoneConnectivity()

    // MARK: - 내부 구성 요소

    private let poseQueue = DispatchQueue(label: "swingwatch.pose")
    private let poseGate = DispatchSemaphore(value: 1)  // 포즈 추정 동시 실행 1개 제한
    private let estimator = PoseEstimator()
    private let detector = SwingDetector()
    private let recorder = SessionRecorder()
    private let speech = SpeechFeedback()

    private var sessionID = UUID()
    private var detectorArmed = false        // poseQueue에서만 접근
    private var bannerHideWork: DispatchWorkItem?
    private var prepared = false

    init() {
        detector.onPhaseChange = { [weak self] phase in
            DispatchQueue.main.async { self?.phase = phase }
        }
        detector.onSwing = { [weak self] capture in
            self?.swingDetected(capture)     // poseQueue에서 호출됨
        }
        camera.frameHandler = { [weak self] sampleBuffer, time in
            self?.handleFrame(sampleBuffer, at: time)
        }
    }

    /// 첫 화면 표시 시 1회 호출.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        connectivity.onCommand = { [weak self] action in
            switch action {
            case .startSession: self?.startSession()
            case .stopSession: self?.stopSession()
            }
        }
        connectivity.activate()
        camera.start()
    }

    // MARK: - 세션 제어 (메인 큐에서 호출)

    func toggleSession() {
        if isSessionActive { stopSession() } else { startSession() }
    }

    func startSession() {
        guard !isSessionActive else { return }
        guard UIApplication.shared.applicationState == .active else {
            // 워치에서 원격 시작했지만 iPhone 앱이 화면에 없으면 카메라를 켤 수 없다.
            connectivity.send(active: false, count: swingCount, latest: latestFeedback)
            return
        }
        sessionID = UUID()
        swingCount = 0
        latestFeedback = nil
        showFeedbackBanner = false
        isSessionActive = true
        UIApplication.shared.isIdleTimerDisabled = true

        if isRecordingEnabled {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            recorder.start(fileName: "session-\(formatter.string(from: Date())).mov")
        }
        poseQueue.async { [weak self] in
            self?.detector.reset()
            self?.detectorArmed = true
        }
        connectivity.send(active: true, count: 0, latest: nil)
    }

    func stopSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        phase = .waiting
        UIApplication.shared.isIdleTimerDisabled = false
        poseQueue.async { [weak self] in self?.detectorArmed = false }
        recorder.finish { _ in }
        connectivity.send(active: false, count: swingCount, latest: latestFeedback)
    }

    // MARK: - 프레임 파이프라인

    /// 카메라 videoQueue에서 매 프레임 호출된다.
    private func handleFrame(_ sampleBuffer: CMSampleBuffer, at time: TimeInterval) {
        recorder.append(sampleBuffer)

        // 포즈 추정이 프레임 속도를 못 따라가면 그 프레임은 건너뛴다.
        guard poseGate.wait(timeout: .now()) == .success else { return }
        let gate = poseGate
        poseQueue.async { [weak self] in
            defer { gate.signal() }
            guard let self else { return }
            if let frame = self.estimator.process(sampleBuffer, at: time) {
                if self.detectorArmed { self.detector.process(frame) }
                DispatchQueue.main.async { self.latestPose = frame }
            } else {
                self.detector.notePoseMissing(at: time)
                DispatchQueue.main.async {
                    if self.latestPose != nil { self.latestPose = nil }
                }
            }
        }
    }

    /// poseQueue에서 호출된다. 분석/평가 후 메인 큐로 넘겨 상태를 갱신한다.
    private func swingDetected(_ capture: SwingCapture) {
        guard let metrics = SwingAnalyzer.analyze(capture) else { return }
        let evaluation = FeedbackEngine.evaluate(metrics)
        let videoFileName = recorder.currentFileName
        let clipStart = recorder.offset(of: capture.addressTime - 1.0).map { max(0, $0) }
        let clipEnd = recorder.offset(of: capture.finishTime + 0.5)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSessionActive else { return }
            self.swingCount += 1
            let feedback = SwingFeedback(
                id: UUID(),
                index: self.swingCount,
                date: Date(),
                score: evaluation.score,
                grade: evaluation.grade,
                tempoRatio: metrics.tempoRatio,
                message: evaluation.message,
                detail: evaluation.detail
            )
            self.latestFeedback = feedback
            self.presentBanner()
            self.speech.speak(evaluation.spokenSummary)
            self.connectivity.send(feedback: feedback)
            self.connectivity.send(active: true, count: self.swingCount, latest: feedback)

            var record = SwingRecord(
                id: feedback.id,
                sessionID: self.sessionID,
                feedback: feedback,
                metrics: metrics,
                videoFileName: nil,
                clipStart: nil,
                clipEnd: nil
            )
            if let videoFileName, let clipStart, let clipEnd {
                record.videoFileName = videoFileName
                record.clipStart = clipStart
                record.clipEnd = clipEnd
            }
            self.store.add(record)
        }
    }

    private func presentBanner() {
        showFeedbackBanner = true
        bannerHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showFeedbackBanner = false }
        bannerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }
}

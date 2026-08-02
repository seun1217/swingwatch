import AVFoundation
import Combine
import CoreMedia
import Foundation

/// 카메라 세션 구성/실행과 프레임 전달을 담당한다.
/// 세션 조작은 sessionQueue, 프레임 콜백은 videoQueue에서 일어난다.
final class CameraManager: NSObject, ObservableObject {

    enum SetupResult: Equatable { case success, notAuthorized, configurationFailed }

    let session = AVCaptureSession()

    /// 세로 회전 보정 이후의 영상 픽셀 크기. 스켈레톤 오버레이 좌표 매핑에 쓴다.
    @Published private(set) var videoSize = CGSize(width: 720, height: 1280)
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var setupResult: SetupResult?

    /// videoQueue에서 호출된다. (버퍼, 버퍼 PTS 초)
    var frameHandler: ((CMSampleBuffer, TimeInterval) -> Void)?

    private let sessionQueue = DispatchQueue(label: "swingwatch.camera.session")
    private let videoQueue = DispatchQueue(label: "swingwatch.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false
    private var internalPosition: AVCaptureDevice.Position = .back

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.sessionQueue.async { self.configureAndRun() }
                } else {
                    self.publish(.notAuthorized)
                }
            }
        default:
            publish(.notAuthorized)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            let newPosition: AVCaptureDevice.Position = self.internalPosition == .back ? .front : .back
            self.session.beginConfiguration()
            let previous = self.currentInput
            if self.attachInput(position: newPosition) {
                self.internalPosition = newPosition
                self.configureConnection()
            } else if let previous, self.session.canAddInput(previous) {
                self.session.addInput(previous)
                self.currentInput = previous
            }
            self.session.commitConfiguration()
            if let device = self.currentInput?.device { self.preferHighFrameRate(device) }
            self.publishState()
        }
    }

    // MARK: - sessionQueue 내부

    private func configureAndRun() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard attachInput(position: internalPosition) else {
                session.commitConfiguration()
                publish(.configurationFailed)
                return
            }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                publish(.configurationFailed)
                return
            }
            session.addOutput(output)
            configureConnection()
            session.commitConfiguration()
            configured = true
            if let device = currentInput?.device { preferHighFrameRate(device) }
        }
        if !session.isRunning { session.startRunning() }
        publish(.success)
        publishState()
    }

    private func attachInput(position: AVCaptureDevice.Position) -> Bool {
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        currentInput = input
        return true
    }

    /// 지원되면 60fps로 올린다(템포 측정 정밀도 향상). 실패해도 30fps로 동작한다.
    private func preferHighFrameRate(_ device: AVCaptureDevice) {
        let target = 60.0
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= target }) else { return }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(target))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // 프레임레이트 설정 실패는 무시하고 기본값으로 동작
        }
    }

    private func configureConnection() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (internalPosition == .front)
        }
    }

    private func publish(_ result: SetupResult) {
        DispatchQueue.main.async { self.setupResult = result }
    }

    private func publishState() {
        var size = CGSize(width: 720, height: 1280)
        if let device = currentInput?.device {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            size = CGSize(width: CGFloat(min(dims.width, dims.height)),
                          height: CGFloat(max(dims.width, dims.height)))
        }
        let position = internalPosition
        DispatchQueue.main.async {
            self.videoSize = size
            self.position = position
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        frameHandler?(sampleBuffer, seconds)
    }
}

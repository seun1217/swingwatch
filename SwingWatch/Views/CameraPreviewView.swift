import AVFoundation
import SwiftUI
import UIKit

/// AVCaptureVideoPreviewLayer를 SwiftUI에서 쓰기 위한 래퍼.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        applyRotation(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // 세션 구성이 늦게 끝나면 connection도 늦게 생기므로 갱신 시점에 재시도한다.
        applyRotation(uiView)
    }

    private func applyRotation(_ view: PreviewView) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}

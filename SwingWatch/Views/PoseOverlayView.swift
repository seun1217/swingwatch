import SwiftUI

/// 인식된 관절 스켈레톤을 카메라 프리뷰 위에 그린다.
/// 프리뷰가 .resizeAspectFill이므로 같은 규칙으로 좌표를 매핑한다.
struct PoseOverlayView: View {

    let pose: PoseFrame?
    let videoSize: CGSize

    private static let bones: [(BodyJoint, BodyJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.neck, .root),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        Canvas { context, size in
            guard let pose, videoSize.width > 0, videoSize.height > 0 else { return }
            let scale = max(size.width / videoSize.width, size.height / videoSize.height)
            let offsetX = (videoSize.width * scale - size.width) / 2
            let offsetY = (videoSize.height * scale - size.height) / 2

            // Vision 좌표: 정규화(0~1), 원점 좌하단 → 뷰 좌표(원점 좌상단)로 변환
            func convert(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * videoSize.width * scale - offsetX,
                        y: (1 - p.y) * videoSize.height * scale - offsetY)
            }

            var path = Path()
            for (a, b) in Self.bones {
                guard let pa = pose.point(a), let pb = pose.point(b) else { continue }
                path.move(to: convert(pa))
                path.addLine(to: convert(pb))
            }
            context.stroke(path, with: .color(.cyan.opacity(0.75)), lineWidth: 3)

            for (_, point) in pose.points {
                let c = convert(point)
                let dot = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(.cyan))
            }
        }
        .allowsHitTesting(false)
    }
}

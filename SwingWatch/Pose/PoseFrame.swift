import CoreGraphics
import Foundation

/// 분석에 사용하는 주요 관절. Vision의 관절 이름과 1:1로 매핑된다.
enum BodyJoint: String, CaseIterable, Codable {
    case nose, neck, root
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip
    case leftKnee, rightKnee
    case leftAnkle, rightAnkle
}

/// 한 프레임의 포즈.
/// 좌표는 영상 기준 정규화(0~1)이고 원점은 좌하단(y는 위로 증가) — Vision 규약 그대로.
struct PoseFrame {
    var time: TimeInterval                  // 카메라 버퍼 타임스탬프(초)
    var points: [BodyJoint: CGPoint]

    func point(_ joint: BodyJoint) -> CGPoint? { points[joint] }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// 두 손목의 중점. 한쪽만 잡히면 그 손목을 쓴다(두 손이 클럽을 같이 잡으므로 근사 가능).
    var handsCenter: CGPoint? {
        switch (points[.leftWrist], points[.rightWrist]) {
        case let (l?, r?): return Self.mid(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    var shoulderCenter: CGPoint? {
        guard let l = points[.leftShoulder], let r = points[.rightShoulder] else {
            return points[.neck]
        }
        return Self.mid(l, r)
    }

    var hipCenter: CGPoint? {
        if let root = points[.root] { return root }
        guard let l = points[.leftHip], let r = points[.rightHip] else { return nil }
        return Self.mid(l, r)
    }

    var shoulderWidth: CGFloat? {
        guard let l = points[.leftShoulder], let r = points[.rightShoulder] else { return nil }
        return hypot(l.x - r.x, l.y - r.y)
    }

    /// 몸통 길이(목~골반). 카메라 거리·화면 크기와 무관한 정규화 기준으로 쓴다.
    var bodyScale: CGFloat? {
        guard let top = points[.neck] ?? shoulderCenter, let bottom = hipCenter else { return nil }
        let d = hypot(top.x - bottom.x, top.y - bottom.y)
        return d > 0.001 ? d : nil
    }
}

import CoreMedia
import Vision

/// Vision 인체 포즈 감지 결과를 PoseFrame으로 변환한다.
/// 무겁기 때문에 전용 직렬 큐(poseQueue)에서만 호출한다.
final class PoseEstimator {

    private static let jointMap: [VNHumanBodyPoseObservation.JointName: BodyJoint] = [
        .nose: .nose, .neck: .neck, .root: .root,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    /// 카메라 연결에서 이미 세로(portrait)로 회전된 버퍼를 받으므로 orientation은 .up이다.
    func process(_ sampleBuffer: CMSampleBuffer, at time: TimeInterval) -> PoseFrame? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              let recognized = try? observation.recognizedPoints(.all) else { return nil }

        var points: [BodyJoint: CGPoint] = [:]
        for (vnName, joint) in Self.jointMap {
            if let candidate = recognized[vnName],
               candidate.confidence >= SwingTuning.minJointConfidence {
                points[joint] = candidate.location
            }
        }
        // 관절이 너무 적으면 신뢰할 수 없는 프레임으로 취급
        guard points.count >= 5 else { return nil }
        return PoseFrame(time: time, points: points)
    }
}

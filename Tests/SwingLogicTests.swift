import CoreGraphics
import XCTest

/// 합성 포즈 시퀀스로 스윙 감지·분석·피드백 로직을 검증한다.
/// (분석 로직 소스가 테스트 타깃에 직접 컴파일되므로 @testable import가 필요 없다.)
final class SwingLogicTests: XCTestCase {

    // MARK: - 합성 스틱 피겨

    /// 정면 뷰 기준. 몸통 길이(목~골반) = 0.30 (정규화 좌표)
    private func frame(at time: TimeInterval,
                       hands: CGPoint,
                       noseX: CGFloat = 0.50,
                       rootX: CGFloat = 0.50) -> PoseFrame {
        var points: [BodyJoint: CGPoint] = [:]
        points[.root] = CGPoint(x: rootX, y: 0.42)
        points[.neck] = CGPoint(x: rootX, y: 0.72)
        points[.nose] = CGPoint(x: noseX, y: 0.80)
        points[.leftShoulder] = CGPoint(x: rootX - 0.06, y: 0.70)
        points[.rightShoulder] = CGPoint(x: rootX + 0.06, y: 0.70)
        points[.leftHip] = CGPoint(x: rootX - 0.04, y: 0.42)
        points[.rightHip] = CGPoint(x: rootX + 0.04, y: 0.42)
        points[.leftWrist] = hands
        points[.rightWrist] = hands
        return PoseFrame(time: time, points: points)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    private func smoothstep(_ u: Double) -> Double {
        let clamped = min(1, max(0, u))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// 어드레스(1.0s) → 백스윙(0.9s) → 다운스윙(0.27s) → 팔로스루(0.45s) → 피니시 정지(0.9s)
    private func fullSwingFrames() -> [PoseFrame] {
        let fps = 30.0
        let dt = 1.0 / fps
        let addressHands = CGPoint(x: 0.50, y: 0.33)
        let topHands = CGPoint(x: 0.60, y: 0.76)
        let impactHands = CGPoint(x: 0.50, y: 0.32)
        let finishHands = CGPoint(x: 0.40, y: 0.74)

        var frames: [PoseFrame] = []
        var t = 0.0
        while t < 1.0 {
            frames.append(frame(at: t, hands: addressHands))
            t += dt
        }
        let backswingEnd = 1.0 + 0.9
        while t < backswingEnd {
            let u = smoothstep((t - 1.0) / 0.9)
            frames.append(frame(at: t, hands: lerp(addressHands, topHands, CGFloat(u))))
            t += dt
        }
        let impactEnd = backswingEnd + 0.27
        while t < impactEnd {
            let u = (t - backswingEnd) / 0.27
            // 다운스윙은 가속(easeIn)
            frames.append(frame(at: t, hands: lerp(topHands, impactHands, CGFloat(u * u))))
            t += dt
        }
        let followEnd = impactEnd + 0.45
        while t < followEnd {
            let u = smoothstep((t - impactEnd) / 0.45)
            frames.append(frame(at: t, hands: lerp(impactHands, finishHands, CGFloat(u))))
            t += dt
        }
        while t < followEnd + 0.9 {
            frames.append(frame(at: t, hands: finishHands))
            t += dt
        }
        return frames
    }

    // MARK: - 테스트

    func testDetectsSingleFullSwing() {
        let detector = SwingDetector()
        var captures: [SwingCapture] = []
        detector.onSwing = { captures.append($0) }

        fullSwingFrames().forEach(detector.process)

        XCTAssertEqual(captures.count, 1, "풀스윙 1회가 정확히 1번 감지되어야 한다")
        guard let capture = captures.first else { return }
        XCTAssertLessThan(capture.addressTime, capture.backswingStart)
        XCTAssertLessThan(capture.backswingStart, capture.topTime)
        XCTAssertLessThan(capture.topTime, capture.impactTime)
        XCTAssertLessThan(capture.impactTime, capture.finishTime)
        XCTAssertGreaterThanOrEqual(capture.frames.count, 8)
    }

    func testWaggleDoesNotTriggerSwing() {
        let dt = 1.0 / 30
        let addressHands = CGPoint(x: 0.50, y: 0.33)
        var frames: [PoseFrame] = []
        var t = 0.0
        while t < 1.0 {
            frames.append(frame(at: t, hands: addressHands))
            t += dt
        }
        // 손을 조금(몸통의 ~27%) 들었다 놓는 왜글
        while t < 1.4 {
            let u = (t - 1.0) / 0.4
            frames.append(frame(at: t, hands: CGPoint(x: 0.50, y: 0.33 + 0.08 * sin(.pi * CGFloat(u)))))
            t += dt
        }
        while t < 2.8 {
            frames.append(frame(at: t, hands: addressHands))
            t += dt
        }

        let detector = SwingDetector()
        var swingCount = 0
        detector.onSwing = { _ in swingCount += 1 }
        frames.forEach(detector.process)

        XCTAssertEqual(swingCount, 0, "왜글은 스윙으로 오인되면 안 된다")
    }

    func testMetricsAndFeedbackForGoodSwing() {
        let detector = SwingDetector()
        var captures: [SwingCapture] = []
        detector.onSwing = { captures.append($0) }
        fullSwingFrames().forEach(detector.process)

        guard let capture = captures.first else {
            XCTFail("스윙이 감지되지 않았다")
            return
        }
        guard let metrics = SwingAnalyzer.analyze(capture) else {
            XCTFail("지표 계산에 실패했다")
            return
        }

        XCTAssertGreaterThan(metrics.tempoRatio, 1.8)
        XCTAssertLessThan(metrics.tempoRatio, 5.0)
        XCTAssertLessThan(metrics.headSway, 0.22, "머리를 고정한 합성 스윙이므로 스웨이가 작아야 한다")
        XCTAssertLessThan(metrics.hipSway, 0.25)

        let evaluation = FeedbackEngine.evaluate(metrics)
        XCTAssertGreaterThanOrEqual(evaluation.score, 70)
        XCTAssertFalse(evaluation.message.isEmpty)
    }

    func testFeedbackFlagsFastTempo() {
        let metrics = SwingMetrics(
            backswingDuration: 0.45,
            downswingDuration: 0.30,
            tempoRatio: 1.5,
            headSway: 0.05,
            hipSway: 0.05,
            shoulderTurnRatio: 0.5,
            hipRise: 0.0,
            peakHandSpeed: 6.0
        )
        let evaluation = FeedbackEngine.evaluate(metrics)
        XCTAssertLessThan(evaluation.score, 100)
        XCTAssertTrue(evaluation.message.contains("템포"), "빠른 템포가 핵심 피드백이어야 한다")
    }

    func testPoseFrameHelpers() {
        let f = frame(at: 0, hands: CGPoint(x: 0.5, y: 0.33))
        XCTAssertNotNil(f.bodyScale)
        XCTAssertEqual(Double(f.bodyScale ?? 0), 0.30, accuracy: 0.001)
        XCTAssertEqual(Double(f.handsCenter?.y ?? 0), 0.33, accuracy: 0.001)
        XCTAssertEqual(Double(f.shoulderWidth ?? 0), 0.12, accuracy: 0.001)
    }
}

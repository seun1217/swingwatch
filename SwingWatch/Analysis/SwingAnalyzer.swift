import CoreGraphics
import Foundation

/// 캡처된 스윙 프레임에서 지표를 계산한다.
enum SwingAnalyzer {

    static func analyze(_ capture: SwingCapture) -> SwingMetrics? {
        let frames = capture.frames
        guard frames.count >= 8 else { return nil }

        // 어드레스 구간(백스윙 시작 전)에서 기준값을 평균낸다.
        let addressWindow = frames.filter {
            $0.time >= capture.addressTime - SwingTuning.preAddressPadding
                && $0.time <= capture.backswingStart
        }
        guard !addressWindow.isEmpty else { return nil }

        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        let noseXs = addressWindow.compactMap { f in
            f.point(.nose).map { Double($0.x) } ?? f.shoulderCenter.map { Double($0.x) }
        }
        guard let scale = average(addressWindow.compactMap { $0.bodyScale.map(Double.init) }),
              scale > 0.001,
              let noseX0 = average(noseXs),
              let hip0 = averagePoint(addressWindow.compactMap { $0.hipCenter })
        else { return nil }

        let shoulderWidth0 = average(addressWindow.compactMap { $0.shoulderWidth.map(Double.init) })

        let backswingFrames = frames.filter {
            $0.time >= capture.backswingStart && $0.time <= capture.topTime
        }
        let untilImpact = frames.filter {
            $0.time >= capture.backswingStart && $0.time <= capture.impactTime
        }
        let downswingFrames = frames.filter {
            $0.time >= capture.topTime && $0.time <= capture.impactTime + 0.05
        }

        // 머리 스웨이: 임팩트 전까지 머리(코)의 좌우 이동 최대치
        var headSway = 0.0
        for f in untilImpact {
            let x = f.point(.nose).map { Double($0.x) } ?? f.shoulderCenter.map { Double($0.x) }
            if let x { headSway = max(headSway, abs(x - noseX0) / scale) }
        }

        // 골반 스웨이: 백스윙 동안 골반이 옆으로 밀린 최대치
        var hipSway = 0.0
        for f in backswingFrames {
            if let hip = f.hipCenter {
                hipSway = max(hipSway, abs(Double(hip.x) - Double(hip0.x)) / scale)
            }
        }

        // 어깨 회전(정면 뷰 근사): 회전할수록 투영된 어깨 폭이 줄어든다.
        // 어드레스에서 이미 어깨 폭이 좁으면(측면 뷰) 측정하지 않는다.
        var shoulderTurnRatio: Double?
        if let w0 = shoulderWidth0, w0 / scale >= 0.55, w0 > 0.001 {
            if let minW = backswingFrames.compactMap({ $0.shoulderWidth.map(Double.init) }).min() {
                shoulderTurnRatio = minW / w0
            }
        }

        // 몸 일어남(early extension 근사): 임팩트 부근 골반 높이 상승
        var hipRise = 0.0
        let impactWindow = frames.filter { abs($0.time - capture.impactTime) <= 0.08 }
        if let hipImpactY = average(impactWindow.compactMap { $0.hipCenter.map { Double($0.y) } }) {
            hipRise = (hipImpactY - Double(hip0.y)) / scale
        }

        // 다운스윙 최대 손 속도
        var peakHandSpeed = 0.0
        var previous: (time: TimeInterval, point: CGPoint)?
        for f in downswingFrames {
            guard let hands = f.handsCenter else { continue }
            if let prev = previous, f.time > prev.time {
                let v = Double(hypot(hands.x - prev.point.x, hands.y - prev.point.y)) / scale / (f.time - prev.time)
                peakHandSpeed = max(peakHandSpeed, v)
            }
            previous = (f.time, hands)
        }

        let backswing = capture.topTime - capture.backswingStart
        let downswing = capture.impactTime - capture.topTime
        guard backswing > 0.05, downswing > 0.02 else { return nil }

        return SwingMetrics(
            backswingDuration: backswing,
            downswingDuration: downswing,
            tempoRatio: backswing / downswing,
            headSway: headSway,
            hipSway: hipSway,
            shoulderTurnRatio: shoulderTurnRatio,
            hipRise: hipRise,
            peakHandSpeed: peakHandSpeed
        )
    }

    private static func averagePoint(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

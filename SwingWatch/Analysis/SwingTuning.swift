import Foundation

/// 스윙 감지/분석 튜닝 상수 모음.
/// 길이는 모두 "몸통 길이(bodyScale)" 배수, 속도는 몸통 길이/초 단위다.
enum SwingTuning {
    // 포즈 신뢰 조건
    static let minJointConfidence: Float = 0.3
    static let minBodyScale: Double = 0.10          // 화면 대비 몸이 너무 작으면 무시
    static let maxFrameGap: TimeInterval = 0.5      // 프레임 공백이 크면 미분 신호 리셋
    static let poseLossReset: TimeInterval = 0.8    // 포즈 유실이 길면 대기 상태로

    // 어드레스
    static let addressMaxHandHeight: Double = 0.15  // 손이 골반 근처/아래에 있어야 어드레스
    static let stillSpeed: Double = 0.6             // 이 미만이면 정지로 간주
    static let addressHoldDuration: TimeInterval = 0.35

    // 테이크어웨이/백스윙
    static let takeawayRise: Double = 0.18          // 어드레스 대비 손 상승량
    static let takeawayVelocity: Double = 0.4
    static let minSwingAmplitude: Double = 0.5      // 풀스윙 판정 최소 상승량(왜글 필터)
    static let topDropVelocity: Double = 0.5        // 톱에서 하강 전환 판정 속도
    static let backswingTimeout: TimeInterval = 2.5
    static let waggleResetDelay: TimeInterval = 0.3 // 움직이다 이만큼 멈추면 재정지로 판단

    // 다운스윙/임팩트
    static let impactHeightDelta: Double = 0.2      // 손이 어드레스 높이 부근으로 복귀하면 임팩트
    static let downswingTimeout: TimeInterval = 1.0

    // 팔로스루/피니시
    static let followThroughMinDuration: TimeInterval = 0.25
    static let finishStillSpeed: Double = 1.0
    static let finishStillDuration: TimeInterval = 0.3
    static let followThroughTimeout: TimeInterval = 2.5

    static let cooldown: TimeInterval = 0.8
    static let bufferDuration: TimeInterval = 12.0  // 포즈 링버퍼 길이
    static let preAddressPadding: TimeInterval = 0.35

    // 신호 스무딩(지수이동평균 계수, 30fps 기준)
    static let positionSmoothing: Double = 0.5
    static let velocitySmoothing: Double = 0.5
}

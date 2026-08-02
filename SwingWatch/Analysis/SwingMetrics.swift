import Foundation

/// 스윙 하나에서 계산된 수치 지표.
/// 길이 단위는 몸통 길이(bodyScale) 배수, 시간은 초.
struct SwingMetrics: Codable, Equatable {
    var backswingDuration: TimeInterval
    var downswingDuration: TimeInterval
    var tempoRatio: Double           // 백스윙 시간 / 다운스윙 시간 (이상적 ~3.0)
    var headSway: Double             // 임팩트까지 머리 좌우 이동 최대치
    var hipSway: Double              // 백스윙 중 골반 좌우 밀림 최대치
    var shoulderTurnRatio: Double?   // 백스윙 중 어깨 투영 폭 최소치 / 어드레스 폭.
                                     // 작을수록 회전이 크다. 측면 뷰 등 측정 불가면 nil
    var hipRise: Double              // 어드레스 대비 임팩트 시 골반 상승(몸 일어남)
    var peakHandSpeed: Double        // 다운스윙 최대 손 속도 (몸통길이/초)
}

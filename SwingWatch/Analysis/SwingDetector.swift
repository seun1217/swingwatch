import CoreGraphics
import Foundation

/// 감지 단계.
enum SwingPhase: Equatable {
    case waiting        // 골퍼/어드레스 대기
    case address        // 어드레스 인식됨
    case backswing
    case downswing
    case followThrough
    case cooldown       // 스윙 직후 잠깐 대기

    var label: String {
        switch self {
        case .waiting: return "대기 중"
        case .address: return "어드레스"
        case .backswing: return "백스윙"
        case .downswing: return "다운스윙"
        case .followThrough: return "팔로스루"
        case .cooldown: return "분석 중"
        }
    }
}

/// 스윙 하나가 끝났을 때 분석기로 넘어가는 캡처 결과.
struct SwingCapture {
    var frames: [PoseFrame]         // 어드레스 직전 ~ 피니시
    var addressTime: TimeInterval   // 어드레스가 확정된 시각
    var backswingStart: TimeInterval
    var topTime: TimeInterval
    var impactTime: TimeInterval
    var finishTime: TimeInterval
}

/// 포즈 프레임 스트림에서 스윙(어드레스→백스윙→톱→다운스윙→임팩트→피니시)을
/// 찾아내는 상태 기계.
///
/// 핵심 신호는 "손(양 손목 중점) 높이"를 몸통 길이로 정규화한 값이다.
/// 정면·후방(다운더라인) 어느 뷰에서든 손은 어드레스에서 낮고 톱에서 높으므로
/// 뷰 방향에 크게 의존하지 않는다.
///
/// 스레드 안전하지 않으므로 반드시 하나의 직렬 큐에서만 호출해야 한다.
final class SwingDetector {

    var onPhaseChange: ((SwingPhase) -> Void)?
    var onSwing: ((SwingCapture) -> Void)?

    private(set) var phase: SwingPhase = .waiting {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }

    // 최근 프레임 링버퍼
    private var buffer: [PoseFrame] = []

    // 스무딩된 신호
    private var lastTime: TimeInterval?
    private var lastPoseTime: TimeInterval?
    private var smoothedHands: CGPoint?
    private var smoothedHeight: Double?     // (손 y - 골반 y) / bodyScale
    private var verticalVelocity: Double = 0
    private var handSpeed: Double = 0

    // 상태별 기억
    private var stillSince: TimeInterval?
    private var addressTime: TimeInterval = 0
    private var addressBaseline: Double = 0
    private var motionStart: TimeInterval?
    private var lastMovingTime: TimeInterval = 0
    private var backswingStart: TimeInterval = 0
    private var topHeight: Double = 0
    private var topTime: TimeInterval = 0
    private var downswingStart: TimeInterval = 0
    private var impactTime: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    func reset() {
        buffer.removeAll()
        lastTime = nil
        lastPoseTime = nil
        smoothedHands = nil
        smoothedHeight = nil
        verticalVelocity = 0
        handSpeed = 0
        stillSince = nil
        motionStart = nil
        phase = .waiting
    }

    /// 포즈를 얻지 못한 프레임도 시각과 함께 알려줘야 유실을 감지할 수 있다.
    func notePoseMissing(at time: TimeInterval) {
        guard let last = lastPoseTime else { return }
        if time - last > SwingTuning.poseLossReset, phase != .waiting, phase != .cooldown {
            reset()
        }
    }

    func process(_ frame: PoseFrame) {
        guard let scaleValue = frame.bodyScale,
              Double(scaleValue) >= SwingTuning.minBodyScale,
              let hands = frame.handsCenter,
              let hip = frame.hipCenter else {
            notePoseMissing(at: frame.time)
            return
        }
        let scale = Double(scaleValue)
        let time = frame.time
        lastPoseTime = time

        // 프레임 공백이 크면 미분 신호를 새로 시작한다.
        if let last = lastTime, time - last > SwingTuning.maxFrameGap {
            lastTime = nil
            smoothedHands = nil
            smoothedHeight = nil
            verticalVelocity = 0
            handSpeed = 0
            stillSince = nil
            motionStart = nil
            if phase != .waiting { phase = .waiting }
        }

        let rawHeight = (Double(hands.y) - Double(hip.y)) / scale

        guard let last = lastTime, let prevHands = smoothedHands, let prevHeight = smoothedHeight else {
            lastTime = time
            smoothedHands = hands
            smoothedHeight = rawHeight
            appendToBuffer(frame)
            return
        }
        let dt = time - last
        guard dt > 0 else { return }

        let pa = SwingTuning.positionSmoothing
        let newHands = CGPoint(x: prevHands.x + (hands.x - prevHands.x) * pa,
                               y: prevHands.y + (hands.y - prevHands.y) * pa)
        let newHeight = prevHeight + (rawHeight - prevHeight) * pa

        let va = SwingTuning.velocitySmoothing
        let instantVerticalVelocity = (newHeight - prevHeight) / dt
        verticalVelocity += (instantVerticalVelocity - verticalVelocity) * va
        let instantSpeed = Double(hypot(newHands.x - prevHands.x, newHands.y - prevHands.y)) / scale / dt
        handSpeed += (instantSpeed - handSpeed) * va

        smoothedHands = newHands
        smoothedHeight = newHeight
        lastTime = time
        appendToBuffer(frame)

        step(time: time, height: newHeight)
    }

    private func appendToBuffer(_ frame: PoseFrame) {
        buffer.append(frame)
        let cutoff = frame.time - SwingTuning.bufferDuration
        if let first = buffer.first, first.time < cutoff {
            buffer.removeAll { $0.time < cutoff }
        }
    }

    private func step(time: TimeInterval, height: Double) {
        switch phase {
        case .waiting:
            guard height < SwingTuning.addressMaxHandHeight,
                  handSpeed < SwingTuning.stillSpeed else {
                stillSince = nil
                return
            }
            if let since = stillSince {
                if time - since >= SwingTuning.addressHoldDuration {
                    addressTime = since
                    addressBaseline = height
                    motionStart = nil
                    phase = .address
                }
            } else {
                stillSince = time
            }

        case .address:
            if handSpeed >= SwingTuning.stillSpeed {
                if motionStart == nil { motionStart = time }
                lastMovingTime = time
            } else {
                // 움직이다 다시 충분히 멈추면(왜글) 시작점을 버린다.
                if motionStart != nil, time - lastMovingTime > SwingTuning.waggleResetDelay {
                    motionStart = nil
                }
                // 정지 중에는 기준 높이가 자세 미세 조정을 천천히 따라가게 한다.
                addressBaseline += (height - addressBaseline) * 0.05
            }

            if height - addressBaseline > SwingTuning.takeawayRise,
               verticalVelocity > SwingTuning.takeawayVelocity {
                backswingStart = motionStart ?? time
                topHeight = height
                topTime = time
                phase = .backswing
            } else if height > 0.6 || handSpeed > 6 {
                // 어드레스 자세가 아님(클럽을 들고 이동 등) → 다시 대기
                stillSince = nil
                phase = .waiting
            }

        case .backswing:
            if height > topHeight {
                topHeight = height
                topTime = time
            }
            let amplitude = topHeight - addressBaseline
            if verticalVelocity < -SwingTuning.topDropVelocity {
                if amplitude >= SwingTuning.minSwingAmplitude {
                    downswingStart = time
                    phase = .downswing
                } else {
                    // 작게 들었다 내려놓음(왜글) → 어드레스로 복귀
                    motionStart = nil
                    phase = .address
                }
            } else if time - backswingStart > SwingTuning.backswingTimeout {
                motionStart = nil
                stillSince = nil
                phase = amplitude >= SwingTuning.minSwingAmplitude ? .waiting : .address
            }

        case .downswing:
            if height <= addressBaseline + SwingTuning.impactHeightDelta {
                impactTime = time
                stillSince = nil
                phase = .followThrough
            } else if time - downswingStart > SwingTuning.downswingTimeout {
                // 하강이 임팩트 지점까지 이어지지 않음(중단된 스윙 등)
                stillSince = nil
                phase = .waiting
            }

        case .followThrough:
            guard time - impactTime >= SwingTuning.followThroughMinDuration else { return }
            if handSpeed < SwingTuning.finishStillSpeed {
                if let since = stillSince {
                    if time - since >= SwingTuning.finishStillDuration {
                        completeSwing(finish: time)
                    }
                } else {
                    stillSince = time
                }
            } else {
                stillSince = nil
                if time - impactTime > SwingTuning.followThroughTimeout {
                    // 피니시 정지가 안 잡혀도 스윙은 완료로 처리
                    completeSwing(finish: time)
                }
            }

        case .cooldown:
            if time >= cooldownUntil {
                stillSince = nil
                phase = .waiting
            }
        }
    }

    private func completeSwing(finish: TimeInterval) {
        let start = addressTime - SwingTuning.preAddressPadding
        let frames = buffer.filter { $0.time >= start && $0.time <= finish }
        let capture = SwingCapture(
            frames: frames,
            addressTime: addressTime,
            backswingStart: backswingStart,
            topTime: topTime,
            impactTime: impactTime,
            finishTime: finish
        )
        cooldownUntil = finish + SwingTuning.cooldown
        stillSince = nil
        phase = .cooldown
        onSwing?(capture)
    }
}

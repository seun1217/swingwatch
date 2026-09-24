import Combine
import Foundation
import WatchKit

/// 연습 세션 동안 워치 앱을 깨어 있게 유지한다.
///
/// 확장 실행 세션(WKExtendedRuntimeSession, Info.plist의 physical-therapy 모드)은
/// 무료 Apple ID로도 쓸 수 있고(HealthKit 워크아웃은 유료 개발자 계정 전용),
/// 켜져 있는 동안에는 손목을 내려도 앱이 중단되지 않아 스윙 피드백을 계속 받는다.
///
/// 제약: 앱이 화면에 떠 있을 때만 시작할 수 있고, 한 번에 최대 1시간까지 유지된다.
final class KeepAliveManager: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published var lastError: String?

    private var session: WKExtendedRuntimeSession?

    func start() {
        guard session == nil else { return }
        guard WKApplication.shared().applicationState == .active else {
            lastError = "워치에서 스윙워치 앱을 연 상태에서 시작할 수 있어요."
            return
        }
        lastError = nil
        let newSession = WKExtendedRuntimeSession()
        newSession.delegate = self
        session = newSession
        newSession.start()
    }

    func stop() {
        session?.invalidate()
        session = nil
        isRunning = false
    }
}

extension WKExtendedRuntimeSessionInvalidationReason {
    fileprivate var koreanDescription: String? {
        switch self {
        case .none, .sessionInProgress: return nil
        case .expired: return "1시간이 지나 백그라운드 유지가 끝났어요. 다시 켜주세요."
        case .resignedFrontmost: return "다른 앱이 열려 백그라운드 유지가 끝났어요."
        case .suppressedBySystem: return "시스템이 백그라운드 유지를 중단했어요(저전력 모드 등)."
        case .error: return "백그라운드 유지를 시작하지 못했어요."
        @unknown default: return "백그라운드 유지가 중단됐어요."
        }
    }
}

extension KeepAliveManager: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.isRunning = true }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // 만료 직전 알림. 백그라운드에서는 새 세션을 시작할 수 없으므로 상태만 정리된다.
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        DispatchQueue.main.async {
            guard self.session === extendedRuntimeSession else { return }
            self.session = nil
            self.isRunning = false
            self.lastError = reason.koreanDescription
        }
    }
}

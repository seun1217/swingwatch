import Combine
import Foundation
import WatchConnectivity
import WatchKit

/// 워치 쪽 WatchConnectivity 관리자.
/// iPhone에서 오는 스윙 피드백/세션 상태를 받고, 세션 제어 명령을 보낸다.
final class WatchConnectivityManager: NSObject, ObservableObject {

    @Published private(set) var isSessionActive = false
    @Published private(set) var swingCount = 0
    @Published private(set) var latest: SwingFeedback?
    @Published private(set) var history: [SwingFeedback] = []
    @Published private(set) var isPhoneReachable = false
    @Published var statusMessage: String?

    /// 세션 시작/종료 상태가 바뀔 때 호출(메인 큐). 자동 워크아웃 연동에 쓴다.
    var onSessionStateChange: ((Bool) -> Void)?

    private let maxHistory = 30

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendCommand(_ action: WatchLink.Action) {
        guard WCSession.default.activationState == .activated else { return }
        statusMessage = nil
        WCSession.default.sendMessage(WatchLink.commandMessage(action), replyHandler: nil) { [weak self] _ in
            DispatchQueue.main.async {
                self?.statusMessage = "iPhone과 연결할 수 없어요.\niPhone에서 스윙워치를 열어주세요."
            }
        }
    }

    // MARK: - 수신 처리

    private func handle(_ message: [String: Any]) {
        guard let kindRaw = message[WatchLink.kindKey] as? String,
              let kind = WatchLink.Kind(rawValue: kindRaw) else { return }
        DispatchQueue.main.async {
            switch kind {
            case .swing:
                if let feedback = WatchLink.decodeFeedback(from: message) {
                    self.apply(feedback, haptic: true)
                }
            case .state:
                if let active = message[WatchLink.activeKey] as? Bool, active != self.isSessionActive {
                    self.isSessionActive = active
                    self.onSessionStateChange?(active)
                }
                if let count = message[WatchLink.countKey] as? Int {
                    self.swingCount = max(self.swingCount, count)
                }
                if let feedback = WatchLink.decodeFeedback(from: message) {
                    self.apply(feedback, haptic: false)
                }
            case .command:
                break
            }
        }
    }

    /// 메인 큐에서 호출. 중복 전달(실시간 + 큐 전송)을 id로 걸러낸다.
    private func apply(_ feedback: SwingFeedback, haptic: Bool) {
        guard !history.contains(where: { $0.id == feedback.id }) else { return }
        history.insert(feedback, at: 0)
        if history.count > maxHistory {
            history.removeLast(history.count - maxHistory)
        }
        if (latest?.date ?? .distantPast) <= feedback.date {
            latest = feedback
        }
        swingCount = max(swingCount, feedback.index)
        if haptic {
            playHaptic(for: feedback.score)
        }
    }

    private func playHaptic(for score: Int) {
        let type: WKHapticType
        switch score {
        case 85...: type = .success
        case 70..<85: type = .notification
        default: type = .retry
        }
        WKInterfaceDevice.current().play(type)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
        // 앱이 늦게 열려도 마지막 세션 상태/피드백을 복원한다.
        handle(session.receivedApplicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isPhoneReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }
}

import Combine
import Foundation
import WatchConnectivity

/// iPhone 쪽 WatchConnectivity 관리자.
/// 스윙 피드백/세션 상태를 워치로 보내고, 워치의 세션 제어 명령을 받는다.
final class PhoneConnectivity: NSObject, ObservableObject {

    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false

    /// 워치에서 세션 제어 명령이 오면 메인 큐에서 호출된다.
    var onCommand: ((WatchLink.Action) -> Void)?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(feedback: SwingFeedback) {
        guard let session, session.activationState == .activated,
              let message = WatchLink.swingMessage(feedback) else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                // 실시간 전송 실패 시 큐 전송으로 대체(워치가 활성화되면 도착)
                session.transferUserInfo(message)
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    func send(active: Bool, count: Int, latest: SwingFeedback?) {
        guard let session, session.activationState == .activated else { return }
        let context = WatchLink.stateMessage(active: active, count: count, latest: latest)
        // 컨텍스트는 "마지막 상태"로 저장되어 워치 앱이 나중에 열려도 복원된다.
        try? session.updateApplicationContext(context)
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }
    }
}

extension PhoneConnectivity: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isReachable = session.isReachable
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 워치 교체 등으로 비활성화되면 새 세션을 다시 활성화한다.
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isReachable = session.isReachable }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.isWatchAppInstalled = session.isWatchAppInstalled }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        guard let action = WatchLink.decodeAction(from: message) else { return }
        DispatchQueue.main.async { self.onCommand?(action) }
    }
}

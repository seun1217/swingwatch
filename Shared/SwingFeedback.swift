import Foundation

/// 한 번의 스윙에 대해 화면·워치로 전달되는 피드백 요약.
/// iOS 앱과 watchOS 앱 양쪽 타깃에 컴파일된다.
struct SwingFeedback: Codable, Identifiable, Equatable {
    var id: UUID
    var index: Int              // 세션 내 스윙 번호 (1부터)
    var date: Date
    var score: Int              // 40~100
    var grade: String           // "A" | "B" | "C" | "D"
    var tempoRatio: Double?     // 백스윙:다운스윙 시간 비율. 측정 불가면 nil
    var message: String         // 핵심 피드백 한 줄
    var detail: String?         // 보조 팁

    var tempoText: String {
        guard let tempoRatio else { return "-" }
        return String(format: "%.1f : 1", tempoRatio)
    }
}

/// iPhone <-> Apple Watch 메시지 규약.
/// WCSession 메시지/컨텍스트는 프로퍼티 리스트 타입만 허용하므로
/// 모델은 JSON Data로 감싸서 넣는다.
enum WatchLink {
    static let kindKey = "kind"
    static let payloadKey = "payload"   // JSON으로 인코딩된 SwingFeedback
    static let activeKey = "active"
    static let countKey = "count"
    static let actionKey = "action"

    enum Kind: String {
        case swing      // phone -> watch: 스윙 피드백
        case state      // phone -> watch: 세션 상태
        case command    // watch -> phone: 세션 제어
    }

    enum Action: String {
        case startSession
        case stopSession
    }

    static func swingMessage(_ feedback: SwingFeedback) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(feedback) else { return nil }
        return [kindKey: Kind.swing.rawValue, payloadKey: data]
    }

    static func stateMessage(active: Bool, count: Int, latest: SwingFeedback?) -> [String: Any] {
        var message: [String: Any] = [
            kindKey: Kind.state.rawValue,
            activeKey: active,
            countKey: count,
        ]
        if let latest, let data = try? JSONEncoder().encode(latest) {
            message[payloadKey] = data
        }
        return message
    }

    static func commandMessage(_ action: Action) -> [String: Any] {
        [kindKey: Kind.command.rawValue, actionKey: action.rawValue]
    }

    static func decodeFeedback(from message: [String: Any]) -> SwingFeedback? {
        guard let data = message[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(SwingFeedback.self, from: data)
    }

    static func decodeAction(from message: [String: Any]) -> Action? {
        guard let kindRaw = message[kindKey] as? String,
              Kind(rawValue: kindRaw) == .command,
              let actionRaw = message[actionKey] as? String else { return nil }
        return Action(rawValue: actionRaw)
    }
}

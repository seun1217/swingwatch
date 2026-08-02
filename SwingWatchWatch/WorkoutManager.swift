import Combine
import Foundation
import HealthKit

/// 연습 세션 동안 골프 워크아웃 세션을 유지한다.
/// 워크아웃이 실행 중이면 손목을 내려도 앱이 계속 살아 있어
/// 스윙 피드백 햅틱을 놓치지 않는다. (데이터는 수집하지 않고 저장도 하지 않는다.)
final class WorkoutManager: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published var lastError: String?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?

    func start() {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
        let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: shareTypes, read: nil) { [weak self] _, _ in
            // 권한이 거부됐다면 세션 시작이 실패하고 didFailWithError로 알 수 있다.
            self?.beginSession()
        }
    }

    func stop() {
        session?.end()
        session = nil
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func beginSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .golf
        configuration.locationType = .outdoor
        do {
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            newSession.delegate = self
            session = newSession
            newSession.startActivity(with: Date())
        } catch {
            DispatchQueue.main.async {
                self.lastError = "워크아웃 세션을 시작하지 못했어요. 헬스 권한을 확인해 주세요."
            }
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        DispatchQueue.main.async {
            self.isRunning = (toState == .running)
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.lastError = "워크아웃 오류: \(error.localizedDescription)"
            self.session = nil
        }
    }
}

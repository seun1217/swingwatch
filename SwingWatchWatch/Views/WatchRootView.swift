import SwiftUI

/// 워치 앱 루트: 세로 페이지 3장(현재 피드백 / 기록 / 설정).
struct WatchRootView: View {

    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        TabView {
            NowView()
            HistoryListView()
            SettingsView()
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            // 세션 상태에 맞춰 워크아웃을 자동 시작/종료해
            // 손목을 내려도 햅틱 피드백을 받을 수 있게 한다.
            connectivity.onSessionStateChange = { [weak workout] active in
                guard UserDefaults.standard.bool(forKey: SettingsKey.autoWorkout),
                      let workout else { return }
                if active {
                    workout.start()
                } else {
                    workout.stop()
                }
            }
        }
    }
}

// MARK: - 현재 피드백

struct NowView: View {

    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let feedback = connectivity.latest {
                    Text("스윙 #\(feedback.index)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(feedback.score)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(scoreColor(feedback.score))
                    Text("\(feedback.grade) · 템포 \(feedback.tempoText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(feedback.message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                } else {
                    Image(systemName: "figure.golf")
                        .font(.largeTitle)
                        .padding(.top, 8)
                    Text(connectivity.isSessionActive
                         ? "첫 스윙을 기다리는 중…"
                         : "iPhone을 세워 두고\n세션을 시작하세요")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                sessionButton
                    .padding(.top, 6)

                if let status = connectivity.statusMessage {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var sessionButton: some View {
        Button {
            connectivity.sendCommand(connectivity.isSessionActive ? .stopSession : .startSession)
        } label: {
            Label(connectivity.isSessionActive ? "세션 종료" : "세션 시작",
                  systemImage: connectivity.isSessionActive ? "stop.fill" : "play.fill")
                .font(.footnote.weight(.semibold))
        }
        .tint(connectivity.isSessionActive ? .red : .green)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...: return .green
        case 70..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - 기록

struct HistoryListView: View {

    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        Group {
            if connectivity.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                    Text("이번 세션 기록이\n여기에 쌓여요")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            } else {
                List(connectivity.history) { feedback in
                    HStack(spacing: 8) {
                        Text("\(feedback.score)")
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(scoreColor(feedback.score))
                            .frame(width: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("#\(feedback.index) · \(feedback.tempoText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(feedback.message)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("기록")
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 85...: return .green
        case 70..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - 설정

struct SettingsView: View {

    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @EnvironmentObject private var workout: WorkoutManager
    @AppStorage(SettingsKey.autoWorkout) private var autoWorkout = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("자동 워크아웃", isOn: $autoWorkout)
                    .font(.footnote)

                Text("세션 중 골프 워크아웃을 실행해 손목을 내려도 햅틱 피드백을 받아요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Circle()
                        .fill(workout.isRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(workout.isRunning ? "워크아웃 실행 중" : "워크아웃 꺼짐")
                        .font(.caption2)
                }

                Button(workout.isRunning ? "워크아웃 종료" : "워크아웃 시작") {
                    if workout.isRunning {
                        workout.stop()
                    } else {
                        workout.start()
                    }
                }
                .font(.footnote)

                HStack {
                    Circle()
                        .fill(connectivity.isPhoneReachable ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(connectivity.isPhoneReachable ? "iPhone 연결됨" : "iPhone 연결 안 됨")
                        .font(.caption2)
                }

                if let error = workout.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("설정")
    }
}

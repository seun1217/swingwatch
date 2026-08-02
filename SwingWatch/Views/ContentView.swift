import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHistory = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraLayer(camera: coordinator.camera, pose: coordinator.latestPose)

            VStack(spacing: 12) {
                topBar
                Spacer()
                if coordinator.showFeedbackBanner, let feedback = coordinator.latestFeedback {
                    FeedbackBannerView(feedback: feedback)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomBar
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: coordinator.showFeedbackBanner)
        .onAppear { coordinator.prepare() }
        .onChange(of: scenePhase) { _, newPhase in
            // 백그라운드로 가면 카메라가 멈추므로 세션도 정리한다.
            if newPhase != .active, coordinator.isSessionActive {
                coordinator.stopSession()
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(store: coordinator.store, isSessionActive: coordinator.isSessionActive)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Label(coordinator.isSessionActive ? coordinator.phase.label : "세션 꺼짐",
                  systemImage: coordinator.isSessionActive ? "figure.golf" : "moon.zzz")
                .font(.footnote.weight(.semibold))
                .chip()

            Text("스윙 \(coordinator.swingCount)")
                .font(.footnote.weight(.semibold))
                .chip()

            Spacer()

            WatchStatusChip(connectivity: coordinator.connectivity)

            Button {
                coordinator.isVoiceEnabled.toggle()
            } label: {
                Image(systemName: coordinator.isVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .chipIcon()
            }

            Button {
                coordinator.camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .chipIcon()
            }
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45), in: Circle())
            }

            Spacer()

            Button {
                coordinator.toggleSession()
            } label: {
                Text(coordinator.isSessionActive ? "세션 종료" : "세션 시작")
                    .font(.headline)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 15)
                    .background(coordinator.isSessionActive ? Color.red : Color.green, in: Capsule())
            }

            Spacer()

            Button {
                coordinator.isRecordingEnabled.toggle()
            } label: {
                Image(systemName: coordinator.isRecordingEnabled ? "record.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(coordinator.isRecordingEnabled ? .red : .white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .disabled(coordinator.isSessionActive)
            .opacity(coordinator.isSessionActive ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(.white)
    }
}

/// 카메라 프리뷰 + 스켈레톤 오버레이 + 권한 안내.
/// CameraManager의 @Published 변화(영상 크기, 권한 상태)를 직접 관찰한다.
private struct CameraLayer: View {
    @ObservedObject var camera: CameraManager
    let pose: PoseFrame?

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
            PoseOverlayView(pose: pose, videoSize: camera.videoSize)
                .ignoresSafeArea()
            if camera.setupResult == .notAuthorized {
                PermissionOverlay()
            }
        }
    }
}

private struct WatchStatusChip: View {
    @ObservedObject var connectivity: PhoneConnectivity

    var body: some View {
        Image(systemName: "applewatch")
            .chipIcon()
            .foregroundStyle(connectivity.isReachable ? Color.green : Color.white.opacity(0.5))
    }
}

private struct PermissionOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
            Text("카메라 권한이 필요해요")
                .font(.headline)
            Text("설정 > 스윙워치에서 카메라 접근을 허용해 주세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(40)
    }
}

private extension View {
    func chip() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
    }

    func chipIcon() -> some View {
        font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.45), in: Circle())
    }
}

import AVKit
import SwiftUI

/// 스윙 하나의 상세 지표와 (세션 영상이 있으면) 해당 구간 재생.
struct SwingDetailView: View {

    let record: SwingRecord
    let isSessionActive: Bool
    @State private var player: AVPlayer?

    var body: some View {
        List {
            Section("피드백") {
                HStack {
                    Text("\(record.feedback.score)점 · \(record.feedback.grade)")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Text(record.feedback.date, style: .time)
                        .foregroundStyle(.secondary)
                }
                Text(record.feedback.message)
                if let detail = record.feedback.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("지표") {
                metricRow("템포", String(format: "%.1f : 1", record.metrics.tempoRatio),
                          String(format: "백스윙 %.2f초 · 다운스윙 %.2f초",
                                 record.metrics.backswingDuration, record.metrics.downswingDuration))
                metricRow("머리 스웨이", percent(record.metrics.headSway), "몸통 길이 대비 · 22% 이하 권장")
                metricRow("골반 스웨이", percent(record.metrics.hipSway), "몸통 길이 대비 · 25% 이하 권장")
                if let turn = record.metrics.shoulderTurnRatio {
                    metricRow("어깨 회전", percent(1 - turn), "어깨 폭 감소량 · 클수록 회전이 큼")
                } else {
                    metricRow("어깨 회전", "-", "정면 촬영에서만 측정돼요")
                }
                metricRow("몸 일어남", percent(record.metrics.hipRise), "임팩트 시 골반 상승 · 10% 이하 권장")
                metricRow("핸드 스피드", String(format: "%.1f", record.metrics.peakHandSpeed), "몸통길이/초 · 세션 내 상대 비교용")
            }

            videoSection
        }
        .navigationTitle("스윙 #\(record.feedback.index)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: setupPlayer)
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var videoSection: some View {
        if let url = record.videoURL, let start = record.clipStart {
            Section("영상") {
                if isSessionActive {
                    Text("세션을 종료하면 재생할 수 있어요.")
                        .foregroundStyle(.secondary)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    VideoPlayer(player: player)
                        .frame(height: 340)
                        .listRowInsets(EdgeInsets())
                    Button {
                        seek(to: start)
                        player?.play()
                    } label: {
                        Label("스윙 구간부터 재생", systemImage: "gobackward")
                    }
                } else {
                    Text("영상 파일을 찾을 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metricRow(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.body.weight(.semibold))
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", max(0, value) * 100)
    }

    private func setupPlayer() {
        guard !isSessionActive,
              player == nil,
              let url = record.videoURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        player = AVPlayer(url: url)
        if let start = record.clipStart {
            seek(to: start)
        }
    }

    private func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

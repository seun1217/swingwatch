import SwiftUI

/// 세션별로 묶인 스윙 기록 목록.
struct HistoryView: View {

    @ObservedObject var store: SwingStore
    let isSessionActive: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "아직 기록이 없어요",
                        systemImage: "figure.golf",
                        description: Text("세션을 시작하고 스윙하면 기록이 쌓입니다.")
                    )
                } else {
                    List {
                        ForEach(store.sessions, id: \.sessionID) { group in
                            Section(sectionTitle(for: group.records)) {
                                ForEach(Array(group.records.reversed())) { record in
                                    NavigationLink {
                                        SwingDetailView(record: record, isSessionActive: isSessionActive)
                                    } label: {
                                        SwingRow(record: record)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("스윙 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        store.deleteAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.records.isEmpty || isSessionActive)
                }
            }
        }
    }

    private func sectionTitle(for records: [SwingRecord]) -> String {
        guard let first = records.first else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) HH:mm"
        let averageScore = records.map(\.feedback.score).reduce(0, +) / max(1, records.count)
        return "\(formatter.string(from: first.feedback.date)) · \(records.count)스윙 · 평균 \(averageScore)점"
    }
}

private struct SwingRow: View {

    let record: SwingRecord

    private var scoreColor: Color {
        switch record.feedback.score {
        case 85...: return .green
        case 70..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(record.feedback.score)")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(scoreColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("#\(record.feedback.index) · \(record.feedback.grade) · 템포 \(record.feedback.tempoText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.feedback.message)
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

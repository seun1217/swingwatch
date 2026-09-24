import SwiftUI

/// 스윙 직후 몇 초 동안 표시되는 피드백 배너.
struct FeedbackBannerView: View {

    let feedback: SwingFeedback

    private var scoreColor: Color {
        switch feedback.score {
        case 85...: return .green
        case 70..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("\(feedback.score)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(feedback.grade)
                    .font(.caption.bold())
            }
            .foregroundStyle(scoreColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("스윙 #\(feedback.index) · 템포 \(feedback.tempoText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(feedback.message)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 8)
    }
}

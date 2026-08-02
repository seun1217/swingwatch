import Foundation

/// 지표를 점수/등급/한국어 피드백 문구로 바꾼다.
enum FeedbackEngine {

    struct Evaluation {
        var score: Int
        var grade: String
        var message: String          // 핵심 피드백(워치/배너 표시)
        var detail: String?          // 보조 팁
        var spokenSummary: String    // 음성 안내용 짧은 문장
    }

    private struct Issue {
        var deduction: Double
        var message: String
        var short: String
    }

    /// 이 값 이상 감점된 문제만 사용자에게 문구로 노출한다.
    private static let significantDeduction = 4.0

    static func evaluate(_ m: SwingMetrics) -> Evaluation {
        var issues: [Issue] = []

        // 템포 (이상적 범위 2.2 ~ 3.8 : 1, 교과서적 기준은 3:1)
        if m.tempoRatio < 2.2 {
            issues.append(Issue(
                deduction: min(18, (2.2 - m.tempoRatio) * 15),
                message: "템포가 급해요. 백스윙을 더 여유 있게, 3:1 리듬을 떠올리세요.",
                short: "템포가 빨라요"
            ))
        } else if m.tempoRatio > 3.8 {
            issues.append(Issue(
                deduction: min(12, (m.tempoRatio - 3.8) * 8),
                message: "백스윙이 다소 느려요. 리듬을 조금만 경쾌하게 가져가 보세요.",
                short: "템포가 느려요"
            ))
        }

        if m.headSway > 0.22 {
            issues.append(Issue(
                deduction: min(20, (m.headSway - 0.22) * 60),
                message: "머리가 좌우로 많이 움직였어요. 시선을 공에 고정해 보세요.",
                short: "머리 움직임이 커요"
            ))
        }

        if m.hipSway > 0.25 {
            issues.append(Issue(
                deduction: min(15, (m.hipSway - 0.25) * 50),
                message: "골반이 옆으로 밀렸어요. 제자리에서 회전하는 느낌으로 하체를 잡아주세요.",
                short: "골반 스웨이가 있어요"
            ))
        }

        if let turn = m.shoulderTurnRatio {
            if turn > 0.75 {
                issues.append(Issue(
                    deduction: 12,
                    message: "어깨 회전이 부족해요. 등이 타깃을 향할 만큼 충분히 돌려주세요.",
                    short: "어깨 회전이 부족해요"
                ))
            } else if turn > 0.62 {
                issues.append(Issue(
                    deduction: 6,
                    message: "어깨 회전을 조금만 더 크게 가져가면 좋아요.",
                    short: "어깨 회전을 더 크게"
                ))
            }
        }

        if m.hipRise > 0.10 {
            issues.append(Issue(
                deduction: min(15, (m.hipRise - 0.10) * 80),
                message: "임팩트에서 몸이 일어났어요. 어드레스 때 엉덩이 높이를 유지해 보세요.",
                short: "몸이 일어났어요"
            ))
        }

        let totalDeduction = issues.reduce(0) { $0 + $1.deduction }
        let score = max(40, min(100, Int((100 - totalDeduction).rounded())))
        let grade: String
        switch score {
        case 90...: grade = "A"
        case 80..<90: grade = "B"
        case 70..<80: grade = "C"
        default: grade = "D"
        }

        let tempoText = String(format: "%.1f : 1", m.tempoRatio)
        let significant = issues
            .filter { $0.deduction >= significantDeduction }
            .sorted { $0.deduction > $1.deduction }

        if let main = significant.first {
            let detail = significant.dropFirst().first?.message ?? "템포 \(tempoText)"
            return Evaluation(
                score: score,
                grade: grade,
                message: main.message,
                detail: detail,
                spokenSummary: "\(score)점. \(main.short)."
            )
        }

        let praises = [
            "아주 좋은 스윙이에요! 이 리듬을 그대로 유지하세요.",
            "밸런스와 템포가 훌륭해요. 굿샷 감각 그대로!",
            "교과서 같은 스윙! 다음 샷도 같은 리듬으로.",
        ]
        let praise = praises[Int((m.tempoRatio * 10).rounded()) % praises.count]
        return Evaluation(
            score: score,
            grade: grade,
            message: praise,
            detail: "템포 \(tempoText)",
            spokenSummary: "\(score)점. 좋은 스윙이에요."
        )
    }
}

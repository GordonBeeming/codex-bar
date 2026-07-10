import CodexBarCore
import SwiftUI

struct LimitRowView: View {
    let limit: UsageLimit
    let now: Date
    let severity: Severity

    private let barHeight: CGFloat = 8
    private let markerWidth: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.name)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.subheadline.bold())
            }

            paceBar

            if let resetsAt = limit.resetsAt {
                Text(
                    "Resets \(ResetFormatting.localResetString(for: resetsAt, now: now)) · \(ResetFormatting.countdownString(until: resetsAt, now: now))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if UsageWindow.isAheadOfPace(for: limit, now: now) {
                Text("🔥 Ahead of pace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var paceBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle()
                        .fill(tintColor)
                        .frame(width: width * min(max(limit.percent, 0), 100) / 100)
                }
                .clipShape(Capsule())

                if let pace = UsageWindow.paceFraction(for: limit, now: now) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: markerWidth)
                        .padding(.leading, markerOffset(pace: pace, width: width))
                }
            }
        }
        .frame(height: barHeight)
        .accessibilityLabel("Usage")
        .accessibilityValue("\(Int(limit.percent.rounded())) percent")
    }

    private func markerOffset(pace: Double, width: CGFloat) -> CGFloat {
        let maximum = max(width - markerWidth, 0)
        return min(max(width * pace - markerWidth / 2, 0), maximum)
    }

    private var tintColor: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

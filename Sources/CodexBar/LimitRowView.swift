import CodexBarCore
import SwiftUI

struct LimitRowView: View {
    private static let aheadOfPaceText = "🔥 Ahead of pace"
    private static let aheadOfPaceAccessibilityLabel = "Ahead of pace"

    let limit: UsageLimit
    let now: Date
    let severity: Severity
    var displayMode: UsageDisplayMode = .used

    private let barHeight: CGFloat = 8
    private let markerWidth: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.name)
                    .font(.subheadline)
                Spacer()
                Text("\(displayedPercent)%")
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
                Text(Self.aheadOfPaceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Self.aheadOfPaceAccessibilityLabel)
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
                        .frame(width: width * displayMode.fillFraction(usedPercent: limit.percent))
                }
                .clipShape(Capsule())

                if let pace = UsageWindow.paceFraction(for: limit, now: now) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: markerWidth)
                        .padding(.leading, markerOffset(
                            fraction: displayMode.markerFraction(paceFraction: pace), width: width
                        ))
                }
            }
        }
        .frame(height: barHeight)
        .accessibilityLabel("Usage")
        .accessibilityValue(barAccessibilityValue)
    }

    /// The whole number shown in the row, flipped to fuel remaining in fuel-tank mode.
    private var displayedPercent: Int {
        Int(displayMode.displayPercent(usedPercent: limit.percent).rounded())
    }

    private var barAccessibilityValue: String {
        displayMode == .fuelTank ? "\(displayedPercent) percent remaining" : "\(displayedPercent) percent"
    }

    private func markerOffset(fraction: Double, width: CGFloat) -> CGFloat {
        let maximum = max(width - markerWidth, 0)
        return min(max(width * fraction - markerWidth / 2, 0), maximum)
    }

    private var tintColor: Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

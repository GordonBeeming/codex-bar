import SwiftUI

struct ThresholdBarView: View {
    @Binding var warningPercent: Double
    @Binding var criticalPercent: Double

    private let barHeight: CGFloat = 14
    private let handleSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let warningX = width * warningPercent / 100
                let criticalX = width * criticalPercent / 100

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(.blue).frame(width: warningX)
                        Rectangle().fill(.orange).frame(width: max(criticalX - warningX, 0))
                        Rectangle().fill(.red)
                    }
                    .frame(height: barHeight)
                    .clipShape(Capsule())

                    handle(at: warningX, color: .orange)
                        .gesture(dragGesture(width: width) { percent in
                            warningPercent = min(percent, criticalPercent - 1)
                        })
                        .accessibilityLabel("Warning threshold")
                        .accessibilityValue("\(Int(warningPercent)) percent")

                    handle(at: criticalX, color: .red)
                        .gesture(dragGesture(width: width) { percent in
                            criticalPercent = max(percent, warningPercent + 1)
                        })
                        .accessibilityLabel("Critical threshold")
                        .accessibilityValue("\(Int(criticalPercent)) percent")
                }
                .coordinateSpace(name: "thresholdBar")
            }
            .frame(height: handleSize)

            HStack {
                Text("Warning \(Int(warningPercent))%").foregroundStyle(.orange)
                Spacer()
                Text("Critical \(Int(criticalPercent))%").foregroundStyle(.red)
            }
            .font(.caption)
        }
    }

    private func handle(at x: CGFloat, color: Color) -> some View {
        Circle()
            .fill(.background)
            .overlay(Circle().strokeBorder(color, lineWidth: 3))
            .frame(width: handleSize, height: handleSize)
            .shadow(radius: 1, y: 0.5)
            .offset(x: x - handleSize / 2)
    }

    private func dragGesture(width: CGFloat, apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("thresholdBar"))
            .onChanged { value in
                guard width > 0 else { return }
                let percent = (value.location.x / width * 100).rounded()
                guard percent.isFinite else { return }
                apply(min(max(percent, 1), 100))
            }
    }
}

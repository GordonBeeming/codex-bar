import AppKit
import CodexBarCore
import SwiftUI

@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18
    private static let openAIKnotTemplateBase64 = "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAACPUlEQVR42nWUT2jPYRzHX5/vLDtYIjU1aav5Ezk4kEzyr5XTipYSCmVFi/zJgYODi3BQIpo/FwdcJg5KiNTCYfPvYGij1MhqhVqZvVw+P76t+V6e7/t5nt7P53l/3u8n+M+nzgOWAEPAw4gYGbdeRMRYBUdpofJfA5wGmoHPiX8BF4ACqAIeRcTgeLIKUXWOneodtTFxvdqvDqv31W61T91dqaxMUpVjs/pCnZx4v/pBPafWlfavVT+pW/+SVRjVdnVQPZu4S32qLk28ISttS7xefanWABQRMaYeAXYCj4DfqdcCoA34qt4C9gGvgWPqHeA78AOYXymzUX2nNqgdqVGoz7KqXnVIvaRWq5PUk3m1j+psNQqgBeiLiAGgDvgeEQLTskNtwGKgFngD7IiIQ8A64AuwPSIssqV/dQQWZQeHgMMR8S4iPgFHk3iX+gD4CWwBNqlNBXAPaFDnAOdzczcwAxgtHTIJ+AYsy/mOiOgD+oGWIiLeAzeAa8CUiFgNXATGgOOpwRzgBDA9IkaBV+NuMlZkh66mPvfVU8BlYGF2pge4mVUM5/5aYFBtAOYCd4uSsJ+BzcA8oBc4DjQBj4FWYC8wNSv4CSwHrgNXslGg1qS5WhJvVG+prYmXpjm7Ep9J87ZP5Oxt6oC6phSFuozHB/VAzk1We9QV5XhRDp66JwPZnQEdzsDOKpn3ttpZDvr4Z6QSl5nASuB3+qodqAZGgHrgCXAwManxP6KJHquKfsCq9NXziHg70UP4B6TL0SUpQ9DsAAAAAElFTkSuQmCC"
    static let strongFlameColor = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        if match == .darkAqua || match == .vibrantDark {
            return NSColor(srgbRed: 0.95, green: 0.26, blue: 0.21, alpha: 1)
        }
        return NSColor(srgbRed: 0.75, green: 0.12, blue: 0.12, alpha: 1)
    }
    static let lightFlameColor = NSColor.systemOrange

    static func image(percent: Int?, severity: Severity, flameColor: NSColor?) -> NSImage {
        let symbol: NSImage? = codexRosette()

        let flameSymbol = (percent != nil ? flameColor : nil).flatMap { flameImage(color: $0) }
        let isTemplate = severity == .normal && flameSymbol == nil
        let tint = tintColor(for: severity)
        let renderedSymbol = symbol.map { isTemplate ? $0 : tinted($0, color: tint) }
        let text = percent.map { " \($0)%" }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textColor: NSColor = isTemplate ? .labelColor : tint
        let attributedText = text.map {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: textColor])
        }

        let symbolSize = renderedSymbol?.size ?? NSSize(width: 16, height: 16)
        let textSize = attributedText?.size() ?? .zero
        let flameSize = flameSymbol?.size ?? .zero
        let spacing: CGFloat = attributedText == nil ? 0 : 2
        let flameSpacing: CGFloat = flameSymbol == nil ? 0 : 2
        let width = symbolSize.width + spacing + textSize.width + flameSpacing + flameSize.width

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            renderedSymbol?.draw(
                at: NSPoint(x: 0, y: (height - symbolSize.height) / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            attributedText?.draw(
                at: NSPoint(x: symbolSize.width + spacing, y: (height - textSize.height) / 2)
            )
            flameSymbol?.draw(
                at: NSPoint(
                    x: symbolSize.width + spacing + textSize.width + flameSpacing,
                    y: (height - flameSize.height) / 2
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func codexRosette() -> NSImage {
        let data = Data(base64Encoded: openAIKnotTemplateBase64)
        let image = data.flatMap(NSImage.init(data:)) ?? NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Codex usage"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    private static func flameImage(color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(
            systemSymbolName: "flame.fill",
            accessibilityDescription: "Ahead of pace"
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }
        return tinted(base, color: color)
    }

    private static func tintColor(for severity: Severity) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            color.set()
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

struct MenuBarLabelView: View {
    let model: UsageViewModel
    let settings: AppSettings
    let celebrations: CelebrationController

    var body: some View {
        let displayedLimit = menuBarLimit(
            in: model.limits,
            selectedID: settings.menuBarPercentageSelection.limitID
        )
        Image(nsImage: MenuBarIconRenderer.image(
            percent: displayedLimit.map { Int($0.percent.rounded()) },
            severity: displayedLimit.map { settings.thresholds.resolve(for: $0) } ?? .normal,
            flameColor: flameColor
        ))
        .onAppear {
            model.attachCelebrations(settings: settings, controller: celebrations)
            model.startPolling()
        }
    }

    private var flameColor: NSColor? {
        guard settings.showMenuBarFlame else { return nil }
        let now = Date()
        let overPace = model.limits.filter { UsageWindow.isAheadOfPace(for: $0, now: now) }
        guard !overPace.isEmpty else { return nil }
        return overPace.contains { $0.group == "weekly" }
            ? MenuBarIconRenderer.strongFlameColor
            : MenuBarIconRenderer.lightFlameColor
    }
}

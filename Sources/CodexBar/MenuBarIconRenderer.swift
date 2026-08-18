import AppKit
import CodexBarCore
import SwiftUI

@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18
    private static let openAIKnotTemplateBase64 = "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"
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
        // The bitmap is high resolution (96px) so it stays sharp on Retina menu bars.
        // Pin the point size to 18 so the extra pixels become the @2x/@3x representation
        // instead of drawing the glyph oversized.
        image.size = NSSize(width: 18, height: 18)
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
            // Percent is flipped to remaining in fuel-tank mode; severity stays keyed to
            // actual usage, so a nearly-empty tank still reads warning/critical.
            percent: displayedLimit.map { Int(settings.usageDisplayMode.displayPercent(usedPercent: $0.percent).rounded()) },
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

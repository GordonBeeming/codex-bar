import AppKit
import CodexBarCore
import SwiftUI

@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18
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
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            for index in 0..<6 {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: CGFloat(index) * 60)
                transform.translateX(by: -center.x, yBy: -center.y)
                transform.concat()

                let loop = NSBezierPath(
                    roundedRect: NSRect(x: 6.1, y: 7.2, width: 3.8, height: 7),
                    xRadius: 1.9,
                    yRadius: 1.9
                )
                loop.lineWidth = 1.35
                loop.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
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
        let highest = model.highest
        Image(nsImage: MenuBarIconRenderer.image(
            percent: highest.map { Int($0.percent.rounded()) },
            severity: highest.map { settings.thresholds.resolve(for: $0) } ?? .normal,
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

import AppKit
import CodexBarCore

extension Notification.Name {
    static let codexBarOpenSettings = Notification.Name("com.gordonbeeming.CodexBar.openSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { URLCommandRouter.shared.handle(url) }
        }
    }
}

/// Handles `codexbar://` links. Any app or web page can open one, so a settings change is
/// always shown for confirmation before it's applied.
@MainActor
final class URLCommandRouter {
    static let shared = URLCommandRouter()

    weak var settings: AppSettings?

    func handle(_ url: URL) {
        let command: TelemetryURLCommand
        do { command = try TelemetryURLCommand.parse(url) }
        catch {
            inform("CodexBar couldn't use that link", error.localizedDescription)
            return
        }
        switch command {
        case .settings:
            NSApp.activate()
            // The menu bar label is always on screen and has SwiftUI's openSettings action.
            NotificationCenter.default.post(name: .codexBarOpenSettings, object: nil)
        case let .telemetry(change):
            confirm(change)
        }
    }

    private func confirm(_ change: TelemetrySettingsChange) {
        guard let settings else { return }
        let lines = change.changeLines(from: settings.telemetryConfiguration)
        guard !lines.isEmpty else {
            inform("Telemetry settings are already set", "The link asks for the values CodexBar already uses.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Change CodexBar telemetry settings?"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let interval = change.intervalMinutes { settings.telemetryIntervalMinutes = interval }
        if let retention = change.retentionDays { settings.telemetryRetentionDays = retention }
        if let directory = change.directory { settings.telemetryDirectory = directory }
        if let enabled = change.enabled { settings.telemetryEnabled = enabled }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

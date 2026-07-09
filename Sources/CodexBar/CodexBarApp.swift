import AppKit
import SwiftUI

@main
struct CodexBarApp: App {
    @State private var model = UsageViewModel()
    @State private var settings = AppSettings()
    @State private var celebrations = CelebrationController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(model: model, settings: settings)
        } label: {
            MenuBarLabelView(model: model, settings: settings, celebrations: celebrations)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, model: model)
        }
    }
}

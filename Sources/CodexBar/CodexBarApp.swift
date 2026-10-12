import AppKit
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: UsageViewModel
    @State private var settings: AppSettings
    @State private var celebrations: CelebrationController

    init() {
        self.init(model: UsageViewModel(), settings: AppSettings())
    }

    init(
        model: UsageViewModel, settings: AppSettings,
        celebrations: CelebrationController = CelebrationController()
    ) {
        _model = State(initialValue: model)
        _settings = State(initialValue: settings)
        _celebrations = State(initialValue: celebrations)
        NSApplication.shared.setActivationPolicy(.accessory)
        URLCommandRouter.shared.settings = settings
        model.start(settings: settings, celebrations: celebrations)
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

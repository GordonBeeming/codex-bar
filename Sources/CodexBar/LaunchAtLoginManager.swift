import ServiceManagement

@MainActor
struct LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled, SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        } else if !enabled, SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

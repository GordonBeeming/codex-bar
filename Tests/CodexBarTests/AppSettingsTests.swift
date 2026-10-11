import Foundation
import Observation
import Synchronization
import XCTest
@testable import CodexBar

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testUnlimitedRetentionPersistsAcrossReload() async throws {
        let suite = "com.gordonbeeming.CodexBar.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.telemetryRetentionDays, 90)
        settings.telemetryRetentionDays = 0
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.telemetryRetentionDays, 0)
        XCTAssertEqual(reloaded.telemetryConfiguration.retentionDays, 0)
        reloaded.telemetryRetentionDays = 45
        XCTAssertEqual(AppSettings(defaults: defaults).telemetryRetentionDays, 45)
    }

    @MainActor
    func testNumericUpdatesNotifyObserversAndPersist() async throws {
        let suite = "com.gordonbeeming.CodexBar.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let notified = Mutex(false)
        withObservationTracking {
            _ = settings.telemetryConfiguration
        } onChange: {
            notified.withLock { $0 = true }
        }
        settings.telemetryIntervalMinutes = 15
        settings.telemetryRetentionDays = 30
        XCTAssertTrue(notified.withLock { $0 })
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.telemetryIntervalMinutes, 15)
        XCTAssertEqual(reloaded.telemetryRetentionDays, 30)
    }
}

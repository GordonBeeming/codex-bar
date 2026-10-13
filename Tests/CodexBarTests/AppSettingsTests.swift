import Foundation
import Observation
import Synchronization
import XCTest
import CodexBarCore
@testable import CodexBar

private struct TelemetryFolderFixture {
    let suite = "com.gordonbeeming.CodexBar.Tests.\(UUID())"
    let defaults: UserDefaults
    let home: URL

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        home = FileManager.default.temporaryDirectory.appending(path: "codexbar-home-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var legacy: URL { TelemetryConfiguration.legacyDefaultDirectory(home: home) }
    var newDefault: URL { TelemetryConfiguration.defaultDirectory(home: home) }

    func writeLegacy(_ name: String, _ content: String) throws {
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: legacy.appending(path: name))
    }

    func read(_ directory: URL, _ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}

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
    func testUnsetTelemetryDirectoryUsesApplicationSupportAndMigratesLegacyFiles() throws {
        let fixture = try TelemetryFolderFixture()
        defer { fixture.cleanUp() }
        try fixture.writeLegacy("codexbar-metrics-2026-10-11.jsonl", "m\n")

        let settings = AppSettings(defaults: fixture.defaults, home: fixture.home)
        settings.migrateLegacyTelemetryFolder()

        XCTAssertEqual(settings.telemetryDirectory, fixture.newDefault.path)
        XCTAssertEqual(try fixture.read(fixture.newDefault, "codexbar-metrics-2026-10-11.jsonl"), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacy.path))
    }

    @MainActor
    func testStoredLegacyDefaultIsClearedAndMigrated() throws {
        let fixture = try TelemetryFolderFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(fixture.legacy.path, forKey: "telemetryDirectory")
        try fixture.writeLegacy("codexbar-logs-2026-10-11.jsonl", "l\n")

        let settings = AppSettings(defaults: fixture.defaults, home: fixture.home)
        settings.migrateLegacyTelemetryFolder()

        XCTAssertEqual(settings.telemetryDirectory, fixture.newDefault.path)
        XCTAssertNil(fixture.defaults.object(forKey: "telemetryDirectory"))
        XCTAssertEqual(try fixture.read(fixture.newDefault, "codexbar-logs-2026-10-11.jsonl"), "l\n")
        // A second launch finds nothing stored and nothing to move.
        let reloaded = AppSettings(defaults: fixture.defaults, home: fixture.home)
        reloaded.migrateLegacyTelemetryFolder()
        XCTAssertEqual(reloaded.telemetryDirectory, fixture.newDefault.path)
    }

    @MainActor
    func testCustomTelemetryDirectoryMeansNoMigration() throws {
        let fixture = try TelemetryFolderFixture()
        defer { fixture.cleanUp() }
        let custom = fixture.home.appending(path: "Elsewhere", directoryHint: .isDirectory)
        fixture.defaults.set(custom.path, forKey: "telemetryDirectory")
        try fixture.writeLegacy("codexbar-metrics-2026-10-11.jsonl", "m\n")

        let settings = AppSettings(defaults: fixture.defaults, home: fixture.home)
        settings.migrateLegacyTelemetryFolder()

        XCTAssertEqual(settings.telemetryDirectory, custom.path)
        XCTAssertEqual(try fixture.read(fixture.legacy, "codexbar-metrics-2026-10-11.jsonl"), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.newDefault.path))
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

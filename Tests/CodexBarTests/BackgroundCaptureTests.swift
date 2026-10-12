import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

final class BackgroundCaptureTests: XCTestCase {
    @MainActor
    func testAppStartsRepeatedCapturesWithoutRenderingMenuBarOrSettings() async throws {
        let suite = "com.gordonbeeming.CodexBar.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Couldn't clean fixture: \(error)") }
            }
        }
        let settings = AppSettings(defaults: defaults)
        settings.telemetryEnabled = true
        settings.telemetryDirectory = directory.path
        let rates = try JSONDecoder().decode(RateLimitsResult.self, from: Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":10}}}".utf8))
        let snapshot = UsageSnapshot(limits: UsageLimitMapper.limits(from: rates), planType: "test", rateLimits: rates,
                                     tokenUsage: nil, tokenUsageError: "Test source has no account summary")
        let model = UsageViewModel(client: FixtureClient(snapshot: snapshot), pollInterval: .milliseconds(40),
                                  captureInterval: { _ in .milliseconds(50) }, codexHome: directory.appending(path: "empty-home"),
                                  telemetryStateURL: directory.appending(path: "state/telemetry-state.json"))
        defer { model.stop() }
        _ = CodexBarApp(model: model, settings: settings)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var captures = 0
        while clock.now < deadline {
            captures = try captureCount(in: directory)
            if captures >= 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(captures, 3, "Background app startup must start capture without a view appearing")
        XCTAssertNotNil(model.lastTelemetryWrite)
        settings.telemetryEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        let pausedCaptures = try captureCount(in: directory)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try captureCount(in: directory), pausedCaptures)
        settings.telemetryEnabled = true
        let resumedDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < resumedDeadline, try captureCount(in: directory) < pausedCaptures + 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(try captureCount(in: directory), pausedCaptures + 2,
                                   "Settings observation must resume captures without a view callback")
    }

    private func captureCount(in directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("codexbar-metrics-") }
        return try files.reduce(0) { count, url in
            count + (try Data(contentsOf: url)).split(separator: 0x0A).count
        }
    }
}

private struct FixtureClient: UsageFetching {
    let snapshot: UsageSnapshot
    func fetchUsage(includeTokenUsage: Bool) async throws -> UsageSnapshot { snapshot }
}

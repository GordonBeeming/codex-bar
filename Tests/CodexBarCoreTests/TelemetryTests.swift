import Foundation
import XCTest
@testable import CodexBarCore

final class TelemetryTests: XCTestCase {
    private func fixture(_ json: String) throws -> RateLimitsResult {
        try JSONDecoder().decode(RateLimitsResult.self, from: Data(json.utf8))
    }

    func testEveryBucketAndWindowHasItsOwnOTLPPoint() throws {
        let result = try fixture("""
        {"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},
         "rateLimitsByLimitId":{
           "codex":{"limitId":null,"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":27,"windowDurationMins":10080}},
           "review":{"limitId":null,"primary":{"usedPercent":12}}
         },"ordinaryUsageAllowed":true,"rateLimitResetCredits":{"availableCount":2,"credits":null}}
        """)
        XCTAssertEqual(UsageLimitMapper.limits(from: result).map(\.id), ["codex.primary", "codex.secondary", "review.primary"])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try OTLPTelemetryEncoder.metrics(result: result, planType: "pro", observedAt: date,
                                                  capturedAt: date, serviceVersion: "0.1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["resourceLogs"])
        let resource = try XCTUnwrap((object["resourceMetrics"] as? [[String: Any]])?.first)
        let scope = try XCTUnwrap((resource["scopeMetrics"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap(scope["metrics"] as? [[String: Any]])
        let used = try XCTUnwrap(metrics.first { $0["name"] as? String == "codex.usage.used_percent" })
        let gauge = try XCTUnwrap(used["gauge"] as? [String: Any])
        let points = try XCTUnwrap(gauge["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(points.compactMap { $0["asDouble"] as? Double }, [3, 27, 12])
        XCTAssertEqual(points.first?["timeUnixNano"] as? String, "1800000000000000000")
        XCTAssertNil(points.first?["asInt"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"intValue\":\"300\""))
        XCTAssertFalse(text.contains("legacy"))
    }

    func testNullableLegacyIDAndOptionalTelemetryFields() throws {
        let result = try fixture("""
        {"rateLimits":{"limitId":null,"primary":{"usedPercent":20},
          "credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},
          "individualLimit":{"limit":"100","used":"12","remainingPercent":88,"resetsAt":2000000000},
          "spendControlReached":false,"rateLimitReachedType":"rate_limit_reached","normalModelSlug":"gpt-example"}}
        """)
        XCTAssertEqual(UsageLimitMapper.limits(from: result).first?.id, "codex.primary")
        XCTAssertEqual(result.rateLimits?.credits?.balance, "12.50")
        let data = try OTLPTelemetryEncoder.metrics(result: result, planType: nil, observedAt: nil,
                                                  capturedAt: Date(), serviceVersion: "test")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("codex.credits.balance"))
        XCTAssertTrue(text.contains("codex.spend_control.remaining_percent"))
        XCTAssertFalse(text.contains("codex.tokens.input"))
        XCTAssertFalse(text.contains("codex.reset_credits.available"))
    }

    func testCreditEventsAreDeduplicatedAndDisappearanceDoesNotMeanRedeemed() async throws {
        let sink = MemorySink()
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let available = try fixture("""
        {"accountId":"a","rateLimitResetCredits":{"availableCount":1,"credits":[
          {"id":"credit-1","status":"available","resetType":"codexRateLimits","grantedAt":1}
        ]}}
        """)
        try await recorder.observeResetCredits(result: available, planType: "pro", at: Date())
        try await recorder.observeResetCredits(result: available, planType: "pro", at: Date())
        var lines = await sink.lines
        XCTAssertEqual(lines.count, 1)
        let missing = try fixture("""
        {"accountId":"a","rateLimitResetCredits":{"availableCount":0,"credits":[]}}
        """)
        try await recorder.observeResetCredits(result: missing, planType: "pro", at: Date())
        let unavailable = try fixture("{\"accountId\":\"a\",\"rateLimitResetCredits\":null}")
        try await recorder.observeResetCredits(result: unavailable, planType: "pro", at: Date())
        lines = await sink.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(String(decoding: lines[1], as: UTF8.self).contains("codex.reset_credit.redeemed"))
        let redeemed = try fixture("""
        {"accountId":"a","rateLimitResetCredits":{"availableCount":0,"credits":[
          {"id":"credit-1","status":"redeemed","resetType":"codexRateLimits","grantedAt":1}
        ]}}
        """)
        try await recorder.observeResetCredits(result: redeemed, planType: "pro", at: Date())
        lines = await sink.lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(String(decoding: lines[2], as: UTF8.self).contains("codex.reset_credit.redeemed"))
        XCTAssertFalse(String(decoding: lines[2], as: UTF8.self).contains("\"resourceMetrics\""))
    }

    func testFailedCreditExportRetriesAndAccountSwitchReseeds() async throws {
        let sink = MemorySink()
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let first = try fixture("{\"accountId\":\"a\",\"rateLimitResetCredits\":{\"availableCount\":1}}")
        await sink.failNext()
        do {
            try await recorder.observeResetCredits(result: first, planType: "pro", at: Date())
            XCTFail("Expected failed export")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        try await recorder.observeResetCredits(result: first, planType: "pro", at: Date())
        let second = try fixture("{\"accountId\":\"b\",\"rateLimitResetCredits\":{\"availableCount\":1}}")
        try await recorder.observeResetCredits(result: second, planType: "pro", at: Date())
        let lines = await sink.lines
        XCTAssertEqual(lines.count, 2)
    }

    func testDailyFilesAppendAndRetentionOnlyDeletesOwnedRegularFiles() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        let sink = LocalTelemetrySink(directory: directory)
        let formatter = ISO8601DateFormatter()
        let today = try XCTUnwrap(formatter.date(from: "2026-10-11T23:59:59Z"))
        let tomorrow = try XCTUnwrap(formatter.date(from: "2026-10-12T00:00:01Z"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["codexbar-metrics-2026-10-09.jsonl", "codexbar-logs-2026-10-10.jsonl", "notes.jsonl", "codexbar-metrics-bad-date.jsonl"] {
            try Data("keep?".utf8).write(to: directory.appending(path: name))
        }
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "codexbar-logs-2020-01-01.jsonl"),
                                                  withDestinationURL: directory.appending(path: "notes.jsonl"))
        try await sink.export(Data("{\"resourceMetrics\":[]}".utf8), signal: .metrics, at: today, retentionDays: 2)
        try await sink.export(Data("{\"resourceMetrics\":[]}".utf8), signal: .metrics, at: today, retentionDays: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "codexbar-metrics-2026-10-09.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "codexbar-logs-2026-10-10.jsonl").path))
        let file = directory.appending(path: "codexbar-metrics-2026-10-11.jsonl")
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, "{\"resourceMetrics\":[]}\n{\"resourceMetrics\":[]}\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try await sink.export(Data("{\"resourceLogs\":[]}".utf8), signal: .logs, at: tomorrow, retentionDays: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "codexbar-logs-2026-10-10.jsonl").path))
        for name in ["notes.jsonl", "codexbar-metrics-bad-date.jsonl", "codexbar-logs-2020-01-01.jsonl", "codexbar-logs-2026-10-12.jsonl"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: name).path))
        }
    }

    func testSymlinkDestinationIsRejected() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "notes")
        try Data("private".utf8).write(to: target)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "codexbar-metrics-2026-10-11.jsonl"), withDestinationURL: target)
        do {
            try await LocalTelemetrySink(directory: directory).export(Data("{}".utf8), signal: .metrics, at: date, retentionDays: 90)
            XCTFail("Expected rejected symlink")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "private")
    }

    func testConfigurationDefaultsAndBounds() {
        let config = TelemetryConfiguration(directory: temporaryDirectory())
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.intervalMinutes, 5)
        XCTAssertEqual(config.retentionDays, 90)
        let bounded = TelemetryConfiguration(intervalMinutes: 0, retentionDays: -3, directory: temporaryDirectory())
        XCTAssertEqual(bounded.intervalMinutes, 1)
        XCTAssertEqual(bounded.retentionDays, 1)
        XCTAssertEqual(TelemetryConfiguration(retentionDays: 0, directory: temporaryDirectory()).retentionDays, 0)
        XCTAssertTrue(TelemetryConfiguration.defaultDirectory.path.hasSuffix("Documents/CodexBar Telemetry"))
    }

    func testUnlimitedRetentionKeepsOldMetricsAndLogsUntilLimitIsRestored() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFiles = ["codexbar-metrics-2020-01-01.jsonl", "codexbar-logs-2020-01-01.jsonl"]
        for name in oldFiles { try Data("{}\n".utf8).write(to: directory.appending(path: name)) }
        let configuration = TelemetryConfiguration(retentionDays: 0, directory: directory)
        let recorder = TelemetryRecorder(sink: LocalTelemetrySink(directory: directory),
                                         retentionDays: configuration.retentionDays, serviceVersion: "test")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        try await recorder.recordSample(result: nil, planType: nil, observedAt: nil, at: date)
        for name in oldFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: name).path)) }
        recorder.updateRetentionDays(90)
        recorder.updateRetentionDays(0)
        try await recorder.recordSample(result: nil, planType: nil, observedAt: nil, at: date)
        for name in oldFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: name).path)) }
        recorder.updateRetentionDays(90)
        try await recorder.recordSample(result: nil, planType: nil, observedAt: nil, at: date)
        for name in oldFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: name).path)) }
    }

    func testConcurrentCreditObservationsAndRetentionChangesKeepOneBaseline() async throws {
        let sink = MemorySink()
        await sink.setDelay(.milliseconds(20))
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let summary = try fixture("{\"rateLimitResetCredits\":{\"availableCount\":1}}")
        async let first: Void = recorder.observeResetCredits(result: summary, planType: "pro", at: Date())
        async let second: Void = recorder.observeResetCredits(result: summary, planType: "pro", at: Date())
        _ = try await (first, second)
        recorder.updateRetentionDays(7)
        try await recorder.observeResetCredits(result: summary, planType: "pro", at: Date())
        let lines = await sink.lines
        XCTAssertEqual(lines.count, 1)
        recorder.stop()
        var cancelled = false
        do {
            try await recorder.recordSample(result: summary, planType: "pro", observedAt: Date(), at: Date())
            XCTFail("Expected stopped recording to cancel")
        } catch is CancellationError { cancelled = true }
        XCTAssertTrue(cancelled)
        let stoppedLines = await sink.lines
        XCTAssertEqual(stoppedLines.count, 1)
    }

    func testFirstObservedRedeemedCreditIsStatusObservationNotNewRedemption() async throws {
        let sink = MemorySink()
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let summary = try fixture("""
        {"rateLimitResetCredits":{"availableCount":0,"credits":[
          {"id":"credit-1","status":"redeemed","resetType":"codexRateLimits","grantedAt":1}
        ]}}
        """)
        try await recorder.observeResetCredits(result: summary, planType: nil, at: Date())
        let lines = await sink.lines
        let text = String(decoding: try XCTUnwrap(lines.first), as: UTF8.self)
        XCTAssertFalse(text.contains("codex.reset_credit.redeemed"))
        XCTAssertTrue(text.contains("codex.reset_credit.status_observed"))
    }

    func testUnfinishedDiskRecordIsRemovedBeforeNextAppend() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        let sink = LocalTelemetrySink(directory: directory)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "codexbar-metrics-2026-10-11.jsonl")
        try Data("{\"resourceMetrics\":[]}\n{\"torn\":".utf8).write(to: file)
        try await sink.export(Data("{\"resourceMetrics\":[]}".utf8), signal: .metrics, at: date, retentionDays: 90)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, "{\"resourceMetrics\":[]}\n{\"resourceMetrics\":[]}\n")
        let warnings = await sink.exportWarnings()
        XCTAssertEqual(warnings.count, 1)
    }

    func testChangingValuesDoNotChangeUsageSeriesIdentity() throws {
        let before = try fixture("{\"rateLimits\":{\"primary\":{\"usedPercent\":5},\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"10\"}}}")
        let after = try fixture("{\"rateLimits\":{\"primary\":{\"usedPercent\":6},\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"9\"},\"rateLimitReachedType\":\"rate_limit_reached\"}}")
        func attributes(_ result: RateLimitsResult, date: Date) throws -> NSDictionary {
            let data = try OTLPTelemetryEncoder.metrics(result: result, planType: "pro", observedAt: date, capturedAt: date, serviceVersion: "test")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let resource = try XCTUnwrap((object["resourceMetrics"] as? [[String: Any]])?.first)
            let scope = try XCTUnwrap((resource["scopeMetrics"] as? [[String: Any]])?.first)
            let metric = try XCTUnwrap((scope["metrics"] as? [[String: Any]])?.first { $0["name"] as? String == "codex.usage.used_percent" })
            let gauge = try XCTUnwrap(metric["gauge"] as? [String: Any])
            let point = try XCTUnwrap((gauge["dataPoints"] as? [[String: Any]])?.first)
            return NSDictionary(dictionary: ["attributes": try XCTUnwrap(point["attributes"])])
        }
        XCTAssertEqual(try attributes(before, date: Date(timeIntervalSince1970: 1)),
                       try attributes(after, date: Date(timeIntervalSince1970: 2)))
    }

    func testAccountTokensHaveSeparateScopeExactIntegersAndHistoricalDailyTimes() throws {
        let usage = try JSONDecoder().decode(AccountTokenUsage.self, from: Data("""
        {"summary":{"lifetimeTokens":9007199254740993,"peakDailyTokens":42,"currentStreakDays":3},
         "dailyUsageBuckets":[{"startDate":"2026-10-01","tokens":42}]}
        """.utf8))
        let data = try OTLPTelemetryEncoder.metrics(result: nil, planType: nil, observedAt: nil,
                                                  capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                  serviceVersion: "test", accountTokens: usage)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"asInt\":\"9007199254740993\""))
        XCTAssertTrue(text.contains("codex.account.daily_tokens"))
        XCTAssertTrue(text.contains("account/usage/read"))
        XCTAssertFalse(text.contains("local_session_files"))
        XCTAssertFalse(text.contains("codex.usage.start_date"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertTrue(text.contains("\"timeUnixNano\":\"\(UInt64(date.timeIntervalSince1970 * 1_000_000_000))\""))
    }

    func testHistoricalDailyBucketsAreOnlyRepeatedWhenChanged() async throws {
        let sink = MemorySink()
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let account = try fixture("{\"accountId\":\"a\",\"rateLimits\":{\"primary\":{\"usedPercent\":5}}}")
        let tokens = try JSONDecoder().decode(AccountTokenUsage.self, from: Data("""
        {"summary":{"lifetimeTokens":50},"dailyUsageBuckets":[
          {"startDate":"2026-10-01","tokens":20},{"startDate":"2026-10-11","tokens":30}]}
        """.utf8))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        try await recorder.recordSample(result: account, planType: "pro", observedAt: date, at: date, accountTokens: tokens)
        try await recorder.recordSample(result: account, planType: "pro", observedAt: date, at: date, accountTokens: tokens)
        let lines = await sink.lines
        XCTAssertTrue(String(decoding: lines[1], as: UTF8.self).contains("2026-10-01"))
        XCTAssertFalse(String(decoding: lines[3], as: UTF8.self).contains("2026-10-01"))
        XCTAssertTrue(String(decoding: lines[3], as: UTF8.self).contains("2026-10-11"))
        XCTAssertTrue(String(decoding: lines[2], as: UTF8.self).contains("codex.account.lifetime"))
    }

    func testStopCancelsExportAlreadyQueuedInSink() async throws {
        let sink = MemorySink()
        await sink.setDelay(.milliseconds(50))
        let recorder = TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "test")
        let task = Task { try await recorder.recordSample(result: nil, planType: nil, observedAt: nil, at: Date()) }
        try await Task.sleep(for: .milliseconds(10))
        recorder.stop()
        do { try await task.value; XCTFail("Expected queued export cancellation") }
        catch is CancellationError {
            let empty = await sink.isEmpty()
            XCTAssertTrue(empty)
        }
    }

    func testWarningsSurviveLaterExportsUntilRead() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        let sink = LocalTelemetrySink(directory: directory)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{torn".utf8).write(to: directory.appending(path: "codexbar-metrics-2026-10-11.jsonl"))
        try await sink.export(Data("{\"resourceMetrics\":[]}".utf8), signal: .metrics, at: date, retentionDays: 90)
        try await sink.export(Data("{\"resourceLogs\":[]}".utf8), signal: .logs, at: date, retentionDays: 90)
        let warnings = await sink.exportWarnings()
        XCTAssertEqual(warnings.count, 1)
        let drained = await sink.exportWarnings()
        XCTAssertTrue(drained.isEmpty)
    }

    func testQueuedWriteUsesUpdatedUnlimitedPolicy() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporary(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFile = directory.appending(path: "codexbar-metrics-2020-01-01.jsonl")
        try Data("{}\n".utf8).write(to: oldFile)
        let activity = TelemetryActivity(retentionDays: 90)
        activity.updateRetentionDays(0)
        try await LocalTelemetrySink(directory: directory).export(
            Data("{\"resourceMetrics\":[]}".utf8), signal: .metrics, at: Date(), retentionDays: 90, activity: activity
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appending(path: "codexbar-test-\(UUID())") }
    private func removeTemporary(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { XCTFail("Couldn't clean fixture: \(error)") }
    }
}

private actor MemorySink: TelemetrySink {
    var lines: [Data] = []
    private var shouldFail = false
    private var delay = Duration.zero
    func setDelay(_ delay: Duration) { self.delay = delay }
    func failNext() { shouldFail = true }
    func isEmpty() -> Bool { lines.isEmpty }
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int, activity: TelemetryActivity?) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        try activity?.check()
        if shouldFail { shouldFail = false; throw CocoaError(.fileWriteNoPermission) }
        lines.append(data)
    }
}

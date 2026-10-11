import Foundation
import XCTest
@testable import CodexBarCore

final class LocalTokenUsageReaderTests: XCTestCase {
    func testUsesLatestCumulativeCountsAndDeduplicatesArchivedCopies() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let id = UUID().uuidString
        let first = home.appending(path: "sessions/rollout-\(id).jsonl")
        try Data((event(input: 10, output: 2) + event(input: 30, output: 5, day: 2)).utf8).write(to: first)
        try Data(event(input: 10, output: 2).utf8).write(to: home.appending(path: "archived_sessions/rollout-\(id).jsonl"))
        try Data(event(input: 20, output: 7).utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
        let reader = LocalTokenUsageReader(codexHome: home)
        let totals = try await reader.collect()
        XCTAssertEqual(totals.sessionCount, 2)
        XCTAssertEqual(totals.counts["input"]?.value, 50)
        XCTAssertEqual(totals.counts["output"]?.value, 12)
        XCTAssertEqual(totals.counts["total"]?.value, 62)
        XCTAssertNil(totals.counts["cached_input"])
        let more = try FileHandle(forWritingTo: first)
        try more.seekToEnd()
        try more.write(contentsOf: Data(event(input: 40, output: 8, day: 3).utf8))
        try more.close()
        let updated = try await reader.collect()
        XCTAssertEqual(updated.counts["input"]?.value, 60)
        XCTAssertEqual(updated.counts["output"]?.value, 15)
    }

    func testIgnoresIncompleteAppendAndNullTokenEvents() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let contents = event(input: 10, output: 2)
            + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n"
            + "{\"type\":\"event_msg\",\"payload\":"
        try Data(contents.utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.counts["input"]?.value, 10)
    }

    func testFindsTokenEventAcrossLargeConversationLines() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let privateText = String(repeating: "private prompt", count: 400_000)
        let conversation = "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(privateText)\"}}\n"
        let file = home.appending(path: "sessions/rollout-\(UUID()).jsonl")
        try Data((event(input: 100, output: 8) + conversation).utf8).write(to: file)
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.counts["total"]?.value, 108)
        let data = try OTLPTelemetryEncoder.metrics(result: nil, planType: nil, observedAt: nil,
                                                  capturedAt: Date(), serviceVersion: "test", localTokens: totals)
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(output.contains("private prompt"))
        XCTAssertTrue(output.contains("local_session_files"))
        XCTAssertTrue(output.contains("retained_local_sessions"))
        XCTAssertTrue(output.contains("\"asInt\":\"108\""))
        XCTAssertFalse(output.contains("account/rateLimits/read"))
    }

    func testOptionalCountsKeepCoverageAndInt64Precision() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let large: Int64 = 9_007_199_254_740_993
        let withCache = event(input: large, output: 2, extra: ",\"cached_input_tokens\":5,\"reasoning_output_tokens\":1,\"cache_write_input_tokens\":3")
        try Data(withCache.utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
        try Data(event(input: 2, output: 1).utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.counts["input"]?.value, large + 2)
        XCTAssertEqual(totals.counts["cached_input"]?.sessionsReporting, 1)
        XCTAssertEqual(totals.counts["input"]?.sessionsReporting, 2)
        let data = try OTLPTelemetryEncoder.metrics(result: nil, planType: nil, observedAt: nil,
                                                  capturedAt: Date(), serviceVersion: "test", localTokens: totals)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"asInt\":\"\(large + 2)\""))
    }

    func testBadFilesAreCountedWithoutDiscardingHealthySessionTotals() async throws {
        for text in [event(input: -1, output: 2), "{invalid}\n"] {
            let home = try temporaryHome()
            defer { clean(home) }
            try Data(text.utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
            try Data(event(input: 20, output: 2).utf8).write(to: home.appending(path: "sessions/rollout-\(UUID()).jsonl"))
            let totals = try await LocalTokenUsageReader(codexHome: home).collect()
            XCTAssertEqual(totals.skippedFiles, 1)
            XCTAssertEqual(totals.sessionCount, 1)
            XCTAssertEqual(totals.counts["total"]?.value, 22)
        }
    }

    func testCopiedForkSubtractsInheritedCountsAndCachesBaselineAcrossAppends() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let parent = UUID().uuidString
        let child = UUID().uuidString
        let inherited = event(input: 100, output: 20)
        try Data((inherited + event(input: 140, output: 22, day: 3)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(parent).jsonl"))
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(parent)\"}}\n"
        let childFile = home.appending(path: "sessions/rollout-\(child).jsonl")
        try Data((metadata + inherited + event(input: 130, output: 25, day: 3)).utf8).write(to: childFile)
        let reader = LocalTokenUsageReader(codexHome: home)
        let totals = try await reader.collect()
        XCTAssertEqual(totals.counts["input"]?.value, 170)
        XCTAssertEqual(totals.counts["output"]?.value, 27)
        XCTAssertEqual(totals.skippedFiles, 0)
        try Data((metadata + inherited + event(input: 150, output: 26, day: 4)).utf8).write(to: childFile)
        let updated = try await reader.collect()
        XCTAssertEqual(updated.counts["input"]?.value, 190)
        XCTAssertEqual(updated.counts["output"]?.value, 28)
    }

    func testRestampedCopiedForkUsesItsOwnHistoryOrdinalInsteadOfParentTime() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let parent = UUID().uuidString
        let child = UUID().uuidString
        try Data(event(input: 200, output: 20, ordinal: 1).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(parent).jsonl"))
        let metadata = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(parent)\",\"subagent_history_start_ordinal\":2}}\n"
        let inherited = event(input: 100, output: 10, day: 3, ordinal: 1)
        let own = event(input: 110, output: 12, day: 4, ordinal: 2)
        try Data((metadata + inherited + own).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(child).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.skippedFiles, 0)
        XCTAssertEqual(totals.sessionCount, 2)
        XCTAssertEqual(totals.counts["input"]?.value, 210)
        XCTAssertEqual(totals.counts["output"]?.value, 22)
    }

    func testForkPrefixIsNotCachedWhileItIsStillBeingCopied() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let child = UUID().uuidString
        let metadata = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"subagent_history_start_ordinal\":3}}\n"
        let file = home.appending(path: "sessions/rollout-\(child).jsonl")
        try Data((metadata + event(input: 50, output: 5, day: 3, ordinal: 1)).utf8).write(to: file)
        let reader = LocalTokenUsageReader(codexHome: home)
        let initial = try await reader.collect()
        XCTAssertEqual(initial.counts["input"]?.value, 0)
        let rest = event(input: 100, output: 10, day: 3, ordinal: 2)
            + event(input: 110, output: 12, day: 4, ordinal: 3)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()
        let complete = try await reader.collect()
        XCTAssertEqual(complete.skippedFiles, 0)
        XCTAssertEqual(complete.counts["input"]?.value, 10)
        XCTAssertEqual(complete.counts["output"]?.value, 2)
    }

    func testExplicitEmptyPrefixDoesNotUseMissingParentUsage() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let child = UUID().uuidString
        let metadata = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(UUID())\",\"subagent_history_start_ordinal\":1}}\n"
        try Data((metadata + event(input: 10, output: 2, day: 3, ordinal: 1)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(child).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.skippedFiles, 0)
        XCTAssertEqual(totals.counts["total"]?.value, 12)
    }

    func testReferencedForkUsesFrozenParentPrefixRatherThanCurrentParentUsage() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let parent = UUID().uuidString
        let child = UUID().uuidString
        let prefix = event(input: 100, output: 20, ordinal: 1)
        try Data((prefix + event(input: 200, output: 30, day: 4, ordinal: 2)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(parent).jsonl"))
        let metadata = "{\"ordinal\":2,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(parent)\",\"subagent_history_start_ordinal\":2,\"history_base\":{\"thread_id\":\"\(parent)\",\"end_ordinal_exclusive\":2,\"end_byte_offset\":\(prefix.utf8.count)}}}\n"
        try Data((metadata + event(input: 150, output: 25, day: 3, ordinal: 3)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(child).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.counts["input"]?.value, 250)
        XCTAssertEqual(totals.counts["output"]?.value, 35)
        XCTAssertEqual(totals.skippedFiles, 0)
    }

    func testUnresolvedForkDoesNotInventOwnTokenUsage() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let child = UUID().uuidString
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(UUID())\"}}\n"
        try Data((metadata + event(input: 150, output: 25, day: 3)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(child).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.sessionCount, 0)
        XCTAssertEqual(totals.skippedFiles, 1)
        XCTAssertTrue(totals.counts.isEmpty)
    }

    func testMissingOrdinalFailsClosedAtReferencedForkBoundary() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let parent = UUID().uuidString
        let child = UUID().uuidString
        try Data(event(input: 100, output: 20).utf8).write(to: home.appending(path: "sessions/rollout-\(parent).jsonl"))
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(child)\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"forked_from_id\":\"\(parent)\",\"forked_from_ordinal_exclusive\":2}}\n"
        try Data((metadata + event(input: 150, output: 25, day: 3)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(child).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.skippedFiles, 1)
        XCTAssertEqual(totals.counts["total"]?.value, 120)
    }

    func testUntypedLegacyMetadataAndBrokenDuplicateKeepHealthyThread() async throws {
        let home = try temporaryHome()
        defer { clean(home) }
        let id = UUID().uuidString
        let metadata = "{\"id\":\"\(id)\",\"timestamp\":\"2026-10-01T00:00:00Z\"}\n"
        try Data((metadata + event(input: 20, output: 2)).utf8)
            .write(to: home.appending(path: "sessions/rollout-\(id).jsonl"))
        try Data("{bad}\n".utf8).write(to: home.appending(path: "archived_sessions/rollout-\(id).jsonl"))
        let totals = try await LocalTokenUsageReader(codexHome: home).collect()
        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.skippedFiles, 0)
        XCTAssertEqual(totals.counts["total"]?.value, 22)
    }

    func testMissingSessionsDoNotInventZeroTokenCounts() async throws {
        let totals = try await LocalTokenUsageReader(codexHome: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)).collect()
        XCTAssertEqual(totals.sessionCount, 0)
        XCTAssertTrue(totals.counts.isEmpty)
        XCTAssertNil(totals.latestObservation)
    }

    private func event(input: Int64, output: Int64, day: Int = 1, extra: String = "", ordinal: Int? = nil) -> String {
        let prefix = ordinal.map { "\"ordinal\":\($0)," } ?? ""
        return "{\(prefix)\"timestamp\":\"2026-10-0\(day)T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"total_tokens\":\(input + output)\(extra)}}}}\n"
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "codexbar-token-test-\(UUID())")
        for child in ["sessions", "archived_sessions"] {
            try FileManager.default.createDirectory(at: home.appending(path: child), withIntermediateDirectories: true)
        }
        return home
    }

    private func clean(_ home: URL) {
        do { try FileManager.default.removeItem(at: home) }
        catch { XCTFail("Couldn't clean fixture: \(error)") }
    }
}

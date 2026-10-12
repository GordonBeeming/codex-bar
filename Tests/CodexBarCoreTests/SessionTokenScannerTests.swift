import Foundation
import XCTest
@testable import CodexBarCore

final class SessionTokenScannerTests: XCTestCase {
    private var home: URL!
    private let sessionID = "019C40FB-7BDB-76F1-A673-5D915C6FA0E0"
    private let forkID = "01A0A193-F49D-7362-91D0-5957D0975BC4"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "codexbar-scan-\(UUID())")
        try FileManager.default.createDirectory(at: home.appending(path: "sessions/2026/10/12"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func file(_ id: String, archived: Bool = false) -> URL {
        archived ? home.appending(path: "archived_sessions/rollout-2026-10-12T10-00-00-\(id).jsonl")
            : home.appending(path: "sessions/2026/10/12/rollout-2026-10-12T10-00-00-\(id).jsonl")
    }

    private func append(_ lines: [String], to url: URL) throws {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func meta(_ extra: String = "") -> String {
        #"{"timestamp":"2026-10-12T10:00:00.000Z","type":"session_meta","payload":{"id":"x","timestamp":"2026-10-12T10:00:00.000Z"\#(extra)}}"#
    }

    private func context(_ model: String) -> String {
        #"{"timestamp":"2026-10-12T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"\#(model)"}}"#
    }

    private func tokens(total: (Int, Int, Int, Int), last: (Int, Int, Int, Int), at time: String = "10:00:02", ordinal: Int? = nil) -> String {
        func usage(_ u: (Int, Int, Int, Int)) -> String {
            #"{"input_tokens":\#(u.0),"cached_input_tokens":\#(u.1),"cache_write_input_tokens":0,"output_tokens":\#(u.2),"reasoning_output_tokens":\#(u.3),"total_tokens":\#(u.0 + u.2)}"#
        }
        let ordinalField = ordinal.map { #""ordinal":\#($0),"# } ?? ""
        return #"{"timestamp":"2026-10-12T\#(time).000Z",\#(ordinalField)"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage(total)),"last_token_usage":\#(usage(last))}}}"#
    }

    private var scanner: SessionTokenScanner { SessionTokenScanner(codexHome: home) }

    func testBaselineCountsNothingThenCountsAppendedTurnsWithCachedInputSubtracted() throws {
        try append([meta(), context("gpt-old"), tokens(total: (100, 40, 10, 2), last: (100, 40, 10, 2))], to: file(sessionID))
        var state = try scanner.baseline(now: Date(timeIntervalSince1970: 1))
        try scanner.scan(&state)
        XCTAssertTrue(state.totals.isEmpty)

        try append([context("gpt-5.5"), tokens(total: (300, 140, 25, 7), last: (200, 100, 15, 5))], to: file(sessionID))
        try scanner.scan(&state)
        let counts = try XCTUnwrap(state.totals["gpt-5.5"])
        XCTAssertEqual(counts.input, 100)
        XCTAssertEqual(counts.cacheRead, 100)
        XCTAssertEqual(counts.output, 15)
        XCTAssertEqual(counts.reasoning, 5)
        XCTAssertEqual(counts.cacheWrite, 0)
        XCTAssertNil(state.totals["gpt-old"])
    }

    func testModelFromBeforeTheBaselineIsUsedAndRepeatedTotalsAreSkipped() throws {
        try append([meta(), context("gpt-5.5"), tokens(total: (100, 0, 10, 0), last: (100, 0, 10, 0))], to: file(sessionID))
        var state = try scanner.baseline(now: Date())
        // Codex re-emits the same total for rate-limit updates; the first one repeats the
        // last total written before the baseline.
        try append([tokens(total: (100, 0, 10, 0), last: (100, 0, 10, 0)),
                    tokens(total: (150, 0, 12, 0), last: (50, 0, 2, 0)),
                    tokens(total: (150, 0, 12, 0), last: (50, 0, 2, 0))], to: file(sessionID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 50)
        XCTAssertEqual(state.totals["gpt-5.5"]?.output, 2)
    }

    func testNewSessionIsReadFromTheStartAndPartialLineWaits() throws {
        var state = try scanner.baseline(now: Date())
        let line = tokens(total: (10, 0, 1, 0), last: (10, 0, 1, 0))
        try append([meta(), context("gpt-5.5")], to: file(sessionID))
        let handle = try FileHandle(forWritingTo: file(sessionID))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.prefix(40).utf8))
        try handle.close()
        try scanner.scan(&state)
        XCTAssertTrue(state.totals.isEmpty)
        let rest = try FileHandle(forWritingTo: file(sessionID))
        try rest.seekToEnd()
        try rest.write(contentsOf: Data((line.dropFirst(40) + "\n").utf8))
        try rest.close()
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 10)
    }

    func testArchivingAndDeletingNeverLowerOrRepeatTheTotals() throws {
        var state = try scanner.baseline(now: Date())
        try append([meta(), context("gpt-5.5"), tokens(total: (10, 0, 1, 0), last: (10, 0, 1, 0))], to: file(sessionID))
        try scanner.scan(&state)
        try FileManager.default.createDirectory(at: home.appending(path: "archived_sessions"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file(sessionID), to: file(sessionID, archived: true))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 10)
        try append([tokens(total: (15, 0, 2, 0), last: (5, 0, 1, 0))], to: file(sessionID, archived: true))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 15)
        try FileManager.default.removeItem(at: file(sessionID, archived: true))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 15)
        XCTAssertTrue(state.cursors.isEmpty)
    }

    func testForkSkipsCopiedParentHistory() throws {
        var state = try scanner.baseline(now: Date())
        try append([
            meta(#","forked_from_id":"\#(sessionID)""#), context("gpt-5.5"),
            tokens(total: (1_000, 0, 100, 0), last: (500, 0, 50, 0), at: "09:59:00"),
            tokens(total: (40, 0, 4, 0), last: (40, 0, 4, 0), at: "10:01:00")
        ], to: file(forkID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 40)
        XCTAssertEqual(state.totals["gpt-5.5"]?.output, 4)
    }

    func testSubagentCopySkipsRowsBelowItsHistoryStartOrdinal() throws {
        var state = try scanner.baseline(now: Date())
        try append([
            meta(#","subagent_history_start_ordinal":5"#), context("gpt-5.5"),
            tokens(total: (1_000, 0, 100, 0), last: (500, 0, 50, 0), at: "10:05:00", ordinal: 3),
            tokens(total: (1_030, 0, 103, 0), last: (30, 0, 3, 0), at: "10:05:01", ordinal: 6)
        ], to: file(forkID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 30)
    }

    func testHistoryBaseForkSkipsCopiedRowsByOrdinalEvenWithNewTimestamps() throws {
        var state = try scanner.baseline(now: Date())
        try append([
            meta(#","forked_from_id":"\#(sessionID)","history_base":{"thread_id":"\#(sessionID)","end_ordinal_exclusive":50}"#),
            context("gpt-5.5"),
            tokens(total: (1_000, 0, 100, 0), last: (1_000, 0, 100, 0), at: "10:00:01", ordinal: 40),
            tokens(total: (1_020, 0, 102, 0), last: (20, 0, 2, 0), at: "10:00:02", ordinal: 55)
        ], to: file(forkID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 20)
    }

    func testTokensWithoutTurnContextAreAttributedToUnknownModel() throws {
        var state = try scanner.baseline(now: Date())
        try append([meta(), tokens(total: (10, 0, 1, 0), last: (10, 0, 1, 0))], to: file(sessionID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["unknown"]?.input, 10)
    }

    func testRunningTotalWithoutAPreviousOneIsNotBackfilledAfterTheBaseline() throws {
        try append([meta(), context("gpt-5.5")], to: file(sessionID))
        var state = try scanner.baseline(now: Date())
        // No last_token_usage and no earlier total: the running total holds pre-baseline usage.
        try append([#"{"timestamp":"2026-10-12T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":90,"total_tokens":990}}}}"#,
                    #"{"timestamp":"2026-10-12T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"cached_input_tokens":0,"output_tokens":95,"total_tokens":1045}}}}"#],
                   to: file(sessionID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 50)
        XCTAssertEqual(state.totals["gpt-5.5"]?.output, 5)
    }

    func testOversizedConversationLinesAreSkippedWithoutLosingTheTurnAfterThem() throws {
        var state = try scanner.baseline(now: Date())
        let huge = #"{"timestamp":"2026-10-12T10:00:01.500Z","type":"response_item","payload":{"type":"message","text":""# + String(repeating: "x", count: 9 * 1024 * 1024) + #""}}"#
        try append([meta(), context("gpt-5.5"), huge, tokens(total: (10, 0, 1, 0), last: (10, 0, 1, 0))], to: file(sessionID))
        try scanner.scan(&state)
        XCTAssertEqual(state.totals["gpt-5.5"]?.input, 10)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file(sessionID).path)[.size] as? UInt64)
        XCTAssertEqual(state.cursors.values.first?.offset, size)
    }

    func testCacheWritesInsideInputAreSubtracted() throws {
        var counts = TokenTypeCounts()
        try counts.add(.init(input: 100, cached: 30, cacheWrite: 20, output: 5, reasoning: 1, total: 105))
        XCTAssertEqual(counts.input, 50)
        XCTAssertEqual(counts.cacheWrite, 20)
        var separate = TokenTypeCounts()
        try separate.add(.init(input: 100, cached: 30, cacheWrite: 20, output: 5, reasoning: 1, total: 125))
        XCTAssertEqual(separate.input, 70)
    }
}

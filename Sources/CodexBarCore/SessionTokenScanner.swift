import Foundation

/// Running token totals for one model, split into the spec's token types.
public struct TokenTypeCounts: Codable, Sendable, Equatable {
    /// Input that was neither read from nor written to the cache.
    public var input: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    /// All output, reasoning included.
    public var output: Int64 = 0
    /// The reasoning part of `output`, never to be added on top of it.
    public var reasoning: Int64 = 0

    public init() {}

    mutating func add(_ usage: SessionTokenScanner.Usage) throws {
        // Codex's input_tokens includes cached input. When total == input + output,
        // cache writes are inside input too; otherwise they were reported on the side.
        let writesInInput = usage.total == usage.input &+ usage.output
        let uncached = usage.input - usage.cached - (writesInInput ? usage.cacheWrite : 0)
        input = try Self.sum(input, max(uncached, 0))
        cacheRead = try Self.sum(cacheRead, usage.cached)
        cacheWrite = try Self.sum(cacheWrite, usage.cacheWrite)
        output = try Self.sum(output, usage.output)
        reasoning = try Self.sum(reasoning, usage.reasoning)
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, rhs >= 0 else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}

/// Where each Codex session file has been read up to, plus the running totals. Persisted
/// between launches so only bytes appended since the last scan are ever read, and so the
/// totals never drop when Codex prunes old session files.
public struct SessionScanState: Codable, Sendable, Equatable {
    struct Cursor: Codable, Sendable, Equatable {
        var path: String
        var offset: UInt64
        /// The model from the latest `turn_context` before `offset`.
        var model: String?
        /// The latest cumulative usage before `offset`, so a repeated `token_count`
        /// (same total, emitted again for a rate-limit update) isn't counted twice.
        var lastTotal: SessionTokenScanner.Usage?
        /// Set when the cursor was placed at the end of a file that already had history.
        /// The model and last total are looked up from that history the first time the
        /// file grows, instead of reading every session at opt-in.
        var needsContext: Bool
        /// History a fork or subagent copied from its parent: rows before this time, or
        /// below this ordinal, were already counted in the parent.
        var copiedThrough: Date?
        var copiedBelowOrdinal: UInt64?
        /// True when this session has been read from its first byte, so its first running
        /// total is all its own usage. A cursor placed at a baseline never gets this.
        var readFromStart: Bool?
    }

    var cursors: [String: Cursor]
    /// Totals keyed by model.
    public internal(set) var totals: [String: TokenTypeCounts]
    /// When counting started: OTLP's `startTimeUnixNano` for every `bar.tokens` point.
    public let countingSince: Date
}

/// Counts tokens from Codex's rollout files (`sessions/` and `archived_sessions/` under
/// `CODEX_HOME`), from the moment tracking turns on.
public struct SessionTokenScanner: Sendable {
    struct Usage: Codable, Sendable, Equatable {
        var input: Int64
        var cached: Int64
        var cacheWrite: Int64
        var output: Int64
        var reasoning: Int64
        var total: Int64
    }

    public struct ScanFailure: Sendable, Equatable {
        public let file: String
        public let message: String
    }

    static let unknownModel = "unknown"
    private static let chunkSize = 4 * 1024 * 1024
    /// Past this, an unfinished line that isn't a record we read is dropped as it streams in.
    /// Prompt and tool-output lines can be far larger; token and context lines never are.
    private static let lineBufferLimit = 1024 * 1024
    private static let contextSearchLimit: UInt64 = 64 * 1024 * 1024

    public let roots: [URL]

    public init(codexHome: URL) {
        roots = [codexHome.appending(path: "sessions"), codexHome.appending(path: "archived_sessions")]
    }

    /// Starts counting from now: every existing session is marked as read to its end, so
    /// turning tracking on never backfills history.
    public func baseline(now: Date) throws -> SessionScanState {
        var cursors: [String: SessionScanState.Cursor] = [:]
        for file in try sessionFiles() {
            cursors[file.id] = .init(path: file.url.path, offset: file.size, needsContext: file.size > 0)
        }
        return SessionScanState(cursors: cursors, totals: [:], countingSince: now)
    }

    /// Reads whatever was appended since the last scan and adds it to the totals.
    ///
    /// A session first seen after the baseline is read from the start, minus any history it
    /// copied from a parent. A file that shrank is re-baselined at its new end. A file that
    /// can't be read keeps its cursor so the next scan retries it, and is reported back.
    @discardableResult
    public func scan(_ state: inout SessionScanState) throws -> [ScanFailure] {
        var seen = Set<String>()
        var failures: [ScanFailure] = []
        for file in try sessionFiles() {
            try Task.checkCancellation()
            seen.insert(file.id)
            var cursor = state.cursors[file.id]
                ?? .init(path: file.url.path, offset: 0, needsContext: false, readFromStart: true)
            // Cursors are keyed by session ID, so a session Codex moves into
            // archived_sessions carries on from where it was rather than replaying.
            cursor.path = file.url.path
            if file.size < cursor.offset {
                // A rewrite can keep rows already counted; only what's appended from here counts.
                cursor = .init(path: file.url.path, offset: file.size, needsContext: true)
            }
            if file.size > cursor.offset {
                // Staged per file so a read that fails part-way can't leave half a file
                // counted while its cursor says none of it was.
                var staged = cursor
                var stagedTotals = state.totals
                do {
                    try read(file.url, upTo: file.size, cursor: &staged, totals: &stagedTotals)
                    cursor = staged
                    state.totals = stagedTotals
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(ScanFailure(file: file.url.lastPathComponent, message: error.localizedDescription))
                    guard state.cursors[file.id] != nil else { continue }
                }
            }
            state.cursors[file.id] = cursor
        }
        // A deleted session can't grow again. Its tokens stay in the totals.
        state.cursors = state.cursors.filter { seen.contains($0.key) }
        return failures
    }

    private struct SessionFile {
        let url: URL
        let id: String
        let size: UInt64
        let modified: Date
    }

    private func sessionFiles() throws -> [SessionFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var byID: [String: SessionFile] = [:]
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path]) }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                // Rollout names end in the session UUID, which survives archiving.
                let suffix = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                guard let id = UUID(uuidString: suffix)?.uuidString else { continue }
                // A session removed while the folder is walked has no values; it simply
                // isn't part of this scan.
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize else { continue }
                let file = SessionFile(url: url, id: id, size: UInt64(size),
                                       modified: values.contentModificationDate ?? .distantPast)
                // Two copies of one session (mid-archive): the longer one has everything.
                if let existing = byID[id], (existing.size, existing.modified) >= (file.size, file.modified) { continue }
                byID[id] = file
            }
            if let enumerationError { throw enumerationError }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func read(
        _ url: URL, upTo size: UInt64, cursor: inout SessionScanState.Cursor, totals: inout [String: TokenTypeCounts]
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        // A read-only handle has nothing to flush, so a failed close can't lose data.
        defer { try? handle.close() }
        // While set, bytes are discarded up to and including the next newline.
        var skippingLine = false
        if cursor.needsContext {
            let context = try Self.context(handle, before: cursor.offset)
            cursor.model = context.model ?? cursor.model
            cursor.lastTotal = context.total ?? cursor.lastTotal
            cursor.needsContext = false
            // A baseline taken mid-write sits inside a line; its tail isn't a whole record.
            if cursor.offset > 0 {
                try handle.seek(toOffset: cursor.offset - 1)
                skippingLine = try handle.read(upToCount: 1)?.first != 0x0A
            }
        }
        try handle.seek(toOffset: cursor.offset)
        var pending = Data()
        var position = cursor.offset
        while position < size {
            try Task.checkCancellation()
            let want = Int(min(UInt64(Self.chunkSize), size - position))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            pending.append(chunk)
            if skippingLine {
                guard let newline = pending.firstIndex(of: 0x0A) else {
                    // The cursor stays at the line's start, so a scan that stops here
                    // resumes cleanly; only the buffered bytes are let go.
                    pending.removeAll(keepingCapacity: true)
                    continue
                }
                pending = Data(pending[pending.index(after: newline)...])
                cursor.offset = position - UInt64(pending.count)
                skippingLine = false
            }
            // Only complete lines are consumed; a trailing partial line is still being
            // written and is picked up whole on a later scan.
            if let lastNewline = pending.lastIndex(of: 0x0A) {
                let complete = pending[pending.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    try consume(line, cursor: &cursor, totals: &totals)
                }
                cursor.offset += UInt64(complete.count)
                pending = Data(pending[pending.index(after: lastNewline)...])
            }
            if pending.count > Self.lineBufferLimit, Self.kind(of: pending) == nil {
                pending.removeAll(keepingCapacity: true)
                skippingLine = true
            }
        }
    }

    private func consume(_ slice: Data, cursor: inout SessionScanState.Cursor, totals: inout [String: TokenTypeCounts]) throws {
        guard let kind = Self.kind(of: slice) else { return }
        let line = Data(slice)
        switch kind {
        case .turnContext:
            if let model = Self.decode(TurnContextLine.self, line)?.payload.model, !model.isEmpty {
                cursor.model = model
            }
        case .sessionMeta:
            guard let meta = Self.decode(SessionMetaLine.self, line)?.payload else { return }
            // Copied rows keep the parent's ordinals, so an explicit boundary is exact.
            // Copies can carry new timestamps, so the creation time is only a fallback.
            if let start = meta.subagent_history_start_ordinal ?? meta.history_base?.end_ordinal_exclusive
                ?? meta.forked_from_ordinal_exclusive {
                cursor.copiedBelowOrdinal = start
            } else if meta.forked_from_id != nil || meta.history_base != nil {
                cursor.copiedThrough = meta.timestamp.flatMap(Self.date)
            }
        case .tokenCount:
            // Codex lines that don't decode are Codex's business; they carry no usage we can use.
            guard let event = Self.decode(TokenCountLine.self, line),
                  let total = event.payload.info?.total_token_usage?.usage else { return }
            guard total != cursor.lastTotal else { return }
            defer { cursor.lastTotal = total }
            if Self.isCopied(event, cursor: cursor) { return }
            // last_token_usage is this turn's own usage. It equals the change in the running
            // total except where a fork's total restarts below its parent's.
            let usage: Usage
            if let last = event.payload.info?.last_token_usage?.usage {
                usage = last
            } else if let previous = cursor.lastTotal {
                usage = Usage(input: total.input - previous.input, cached: total.cached - previous.cached,
                              cacheWrite: total.cacheWrite - previous.cacheWrite, output: total.output - previous.output,
                              reasoning: total.reasoning - previous.reasoning, total: total.total - previous.total)
            } else if cursor.readFromStart == true {
                usage = total
            } else {
                // The total before the baseline wasn't found, so this one includes history
                // from before tracking started. It only becomes the reference point.
                return
            }
            guard [usage.input, usage.cached, usage.cacheWrite, usage.output, usage.reasoning].allSatisfy({ $0 >= 0 }) else { return }
            try totals[cursor.model ?? Self.unknownModel, default: TokenTypeCounts()].add(usage)
        }
    }

    private static func isCopied(_ event: TokenCountLine, cursor: SessionScanState.Cursor) -> Bool {
        if let start = cursor.copiedBelowOrdinal {
            // Without an ordinal the row can't be placed; leaving it out undercounts at
            // worst, where counting it could add the parent's whole history again.
            guard let ordinal = event.ordinal else { return true }
            return ordinal < start
        }
        if let copiedThrough = cursor.copiedThrough {
            guard let date = event.timestamp.flatMap(date) else { return true }
            return date <= copiedThrough
        }
        return false
    }

    /// The latest model and cumulative usage written before `offset`, read backwards with
    /// bounded memory.
    static func context(_ handle: FileHandle, before offset: UInt64) throws -> (model: String?, total: Usage?) {
        var model: String?
        var total: Usage?
        var position = offset
        var carry = Data()
        var searched: UInt64 = 0
        while position > 0, model == nil || total == nil, searched < contextSearchLimit {
            try Task.checkCancellation()
            let length = min(position, 65_536)
            position -= length
            searched += length
            try handle.seek(toOffset: position)
            guard var combined = try handle.read(upToCount: Int(length)), combined.count == Int(length) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            combined.append(carry)
            var lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            // The first piece may continue in the previous block.
            carry = position > 0 ? Data(lines.removeFirst()) : Data()
            // Prompt and tool-output lines can be huge; they never hold what we're after.
            if carry.count > 4 * 1024 * 1024 { carry = Data() }
            for line in lines.reversed() where !line.isEmpty {
                let data = Data(line)
                switch kind(of: data) {
                case .turnContext where model == nil:
                    model = decode(TurnContextLine.self, data)?.payload.model
                case .tokenCount where total == nil:
                    total = decode(TokenCountLine.self, data)?.payload.info?.total_token_usage?.usage
                default:
                    break
                }
                if model != nil, total != nil { break }
            }
        }
        return (model, total)
    }

    private enum LineKind { case turnContext, sessionMeta, tokenCount }

    private static let turnContextMarker = Data("\"type\":\"turn_context\"".utf8)
    private static let sessionMetaMarker = Data("\"type\":\"session_meta\"".utf8)
    private static let tokenCountMarker = Data("\"type\":\"token_count\"".utf8)

    /// Codex writes the record type ahead of its payload, so the first bytes are enough to
    /// skip conversation and tool lines without decoding them.
    private static func kind(of line: Data) -> LineKind? {
        let head = line.prefix(512)
        if head.range(of: tokenCountMarker) != nil { return .tokenCount }
        if head.range(of: turnContextMarker) != nil { return .turnContext }
        if head.range(of: sessionMetaMarker) != nil { return .sessionMeta }
        return nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private struct RawUsage: Decodable {
        let input_tokens: Int64?
        let cached_input_tokens: Int64?
        let cache_write_input_tokens: Int64?
        let output_tokens: Int64?
        let reasoning_output_tokens: Int64?
        let total_tokens: Int64?

        var usage: Usage? {
            guard let input_tokens, let output_tokens else { return nil }
            return Usage(input: input_tokens, cached: cached_input_tokens ?? 0,
                         cacheWrite: cache_write_input_tokens ?? 0, output: output_tokens,
                         reasoning: reasoning_output_tokens ?? 0, total: total_tokens ?? input_tokens + output_tokens)
        }
    }

    private struct TokenCountLine: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                let total_token_usage: RawUsage?
                let last_token_usage: RawUsage?
            }
            let info: Info?
        }
        let timestamp: String?
        let ordinal: UInt64?
        let payload: Payload
    }

    private struct TurnContextLine: Decodable {
        struct Payload: Decodable { let model: String? }
        let payload: Payload
    }

    private struct SessionMetaLine: Decodable {
        struct HistoryBase: Decodable { let end_ordinal_exclusive: UInt64? }
        struct Payload: Decodable {
            let timestamp: String?
            let forked_from_id: String?
            let forked_from_ordinal_exclusive: UInt64?
            let history_base: HistoryBase?
            let subagent_history_start_ordinal: UInt64?
        }
        let payload: Payload
    }
}

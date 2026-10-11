import Foundation

public struct LocalTokenTotals: Sendable {
    public struct Count: Sendable {
        public let value: Int64
        public let sessionsReporting: Int
    }
    public let counts: [String: Count]
    public let sessionCount: Int
    public let latestObservation: Date?
    public let skippedFiles: Int
}

public actor LocalTokenUsageReader {
    private struct Usage: Decodable, Sendable {
        let input_tokens: Int64
        let output_tokens: Int64
        let total_tokens: Int64
        let cached_input_tokens: Int64?
        let cache_write_input_tokens: Int64?
        let reasoning_output_tokens: Int64?

        var counts: [String: Int64] {
            var values = ["input": input_tokens, "output": output_tokens, "total": total_tokens]
            values["cached_input"] = cached_input_tokens
            values["cache_write_input"] = cache_write_input_tokens
            values["reasoning_output"] = reasoning_output_tokens
            return values
        }
    }
    private struct TokenEvent: Decodable {
        let timestamp: String?
        let usage: Usage?
        let ordinal: UInt64?

        private enum Keys: String, CodingKey { case type, timestamp, payload, ordinal }
        private enum PayloadKeys: String, CodingKey { case type, info }
        private struct Info: Decodable { let total_token_usage: Usage? }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            ordinal = try values.decodeIfPresent(UInt64.self, forKey: .ordinal)
            guard try values.decodeIfPresent(String.self, forKey: .type) == "event_msg" else {
                timestamp = nil; usage = nil; return
            }
            let payload = try values.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            guard try payload.decodeIfPresent(String.self, forKey: .type) == "token_count" else {
                timestamp = nil; usage = nil; return
            }
            timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp)
            usage = try payload.decodeIfPresent(Info.self, forKey: .info)?.total_token_usage
        }
    }
    private struct Reading: Sendable {
        let counts: [String: Int64]
        let observedAt: Date
        let ordinal: UInt64?
    }
    private struct Metadata: Decodable, Sendable, Equatable {
        struct HistoryBase: Decodable, Sendable, Equatable {
            let thread_id: String
            let end_ordinal_exclusive: UInt64
            let end_byte_offset: Int?
        }
        let id: String
        let timestamp: String
        let forked_from_id: String?
        let forked_from_ordinal_exclusive: UInt64?
        let subagent_history_start_ordinal: UInt64?
        let history_base: HistoryBase?
    }
    private struct CachedFile {
        let size: Int
        let modified: Date
        let reading: Reading?
        let metadata: Metadata?
    }
    private struct Baseline {
        let metadata: Metadata
        let size: Int
        let reading: Reading?
    }

    private let roots: [URL]
    private var cache: [URL: CachedFile] = [:]
    private var baselines: [URL: Baseline] = [:]

    public init(codexHome: URL) {
        roots = [codexHome.appending(path: "sessions"), codexHome.appending(path: "archived_sessions")]
    }

    public func collect() throws -> LocalTokenTotals {
        var files = Set<URL>()
        var pathsByID: [String: URL] = [:]
        var failedThreads = Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path]) }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let suffix = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                guard let id = UUID(uuidString: suffix)?.uuidString else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    // Rollout names supply an identity for older files; canonical
                    // metadata takes precedence when it is present.
                    guard let size = values.fileSize, let modified = values.contentModificationDate else {
                        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
                    }
                    files.insert(url)
                    if cache[url]?.size != size || cache[url]?.modified != modified {
                        let metadata = try Self.metadata(in: url)
                        let reading = try Self.latestReading(in: url, size: size)
                        cache[url] = CachedFile(size: size, modified: modified, reading: reading, metadata: metadata)
                    }
                    let threadID = cache[url]?.metadata.flatMap { UUID(uuidString: $0.id)?.uuidString } ?? id
                    if let previous = pathsByID[threadID],
                       (cache[previous]?.reading?.observedAt ?? .distantPast) >= (cache[url]?.reading?.observedAt ?? .distantPast) {
                        continue
                    }
                    pathsByID[threadID] = url
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let failedID = cache[url]?.metadata.flatMap { UUID(uuidString: $0.id)?.uuidString } ?? id
                    cache[url] = nil
                    baselines[url] = nil
                    failedThreads.insert(failedID)
                }
            }
            if let enumerationError { throw enumerationError }
        }
        cache = cache.filter { files.contains($0.key) }
        baselines = baselines.filter { files.contains($0.key) }
        var skippedFiles = failedThreads.subtracting(Set(pathsByID.keys)).count
        var sessions: [Reading] = []
        for (_, url) in pathsByID {
            guard let cached = cache[url], let latest = cached.reading else { continue }
            do {
                var counts = latest.counts
                if let metadata = cached.metadata,
                   metadata.forked_from_id != nil || metadata.history_base != nil || metadata.subagent_history_start_ordinal != nil {
                    let baseline: Reading?
                    if let saved = baselines[url], saved.metadata == metadata, saved.size <= cached.size {
                        baseline = saved.reading
                    } else {
                        guard let createdAt = Self.date(metadata.timestamp) else { throw CocoaError(.coderInvalidValue) }
                        // Copied history is written with new timestamps. Its
                        // explicit ordinal boundary identifies the inherited
                        // prefix even when every row is newer than metadata.
                        let copied: Reading?
                        if let start = metadata.subagent_history_start_ordinal {
                            copied = try Self.latestReading(in: url, size: cached.size, ordinalLimit: start)
                        } else {
                            copied = try Self.latestReading(in: url, size: cached.size, before: createdAt)
                        }
                        if let copied {
                            baseline = copied
                        } else if let base = metadata.history_base {
                            baseline = try inheritedReading(threadID: base.thread_id, paths: pathsByID,
                                                            byteLimit: base.end_byte_offset,
                                                            ordinalLimit: base.end_ordinal_exclusive, before: createdAt)
                        } else if metadata.subagent_history_start_ordinal != nil {
                            baseline = nil
                        } else if let parent = metadata.forked_from_id {
                            baseline = try inheritedReading(threadID: parent, paths: pathsByID, byteLimit: nil,
                                                            ordinalLimit: metadata.forked_from_ordinal_exclusive, before: createdAt)
                        } else { throw CocoaError(.fileReadCorruptFile) }
                        let prefixComplete = metadata.subagent_history_start_ordinal.map { start in
                            latest.ordinal.map { $0 >= start } ?? false
                        } ?? true
                        if prefixComplete {
                            baselines[url] = Baseline(metadata: metadata, size: cached.size, reading: baseline)
                        }
                    }
                    if let baseline {
                        counts = try counts.reduce(into: [:]) { result, item in
                            guard let inherited = baseline.counts[item.key] else { return }
                            let (value, overflow) = item.value.subtractingReportingOverflow(inherited)
                            guard !overflow, value >= 0 else { throw CocoaError(.coderInvalidValue) }
                            result[item.key] = value
                        }
                    }
                }
                sessions.append(Reading(counts: counts, observedAt: latest.observedAt, ordinal: latest.ordinal))
            } catch is CancellationError { throw CancellationError() }
            catch { skippedFiles += 1 }
        }
        var sums: [String: LocalTokenTotals.Count] = [:]
        for reading in sessions {
            for (kind, count) in reading.counts {
                guard count >= 0 else { throw CocoaError(.coderInvalidValue) }
                let previous = sums[kind]
                let (value, overflow) = (previous?.value ?? 0).addingReportingOverflow(count)
                guard !overflow else { throw CocoaError(.coderInvalidValue) }
                sums[kind] = .init(value: value, sessionsReporting: (previous?.sessionsReporting ?? 0) + 1)
            }
        }
        return LocalTokenTotals(counts: sums, sessionCount: sessions.count,
                                latestObservation: sessions.map(\.observedAt).max(), skippedFiles: skippedFiles)
    }

    private func inheritedReading(
        threadID: String, paths: [String: URL], byteLimit: Int?, ordinalLimit: UInt64?, before: Date,
        visited: Set<String> = []
    ) throws -> Reading? {
        guard let id = UUID(uuidString: threadID)?.uuidString, !visited.contains(id),
              let url = paths[id], let cached = cache[url] else { throw CocoaError(.fileReadNoSuchFile) }
        let size = min(cached.size, byteLimit ?? cached.size)
        if let reading = try Self.latestReading(in: url, size: size, before: before, ordinalLimit: ordinalLimit) {
            return reading
        }
        if let base = cached.metadata?.history_base {
            return try inheritedReading(threadID: base.thread_id, paths: paths, byteLimit: base.end_byte_offset,
                                        ordinalLimit: base.end_ordinal_exclusive, before: before,
                                        visited: visited.union([id]))
        }
        if let metadata = cached.metadata, let parent = metadata.forked_from_id {
            guard let createdAt = Self.date(metadata.timestamp) else { throw CocoaError(.coderInvalidValue) }
            return try inheritedReading(threadID: parent, paths: paths, byteLimit: nil,
                                        ordinalLimit: metadata.forked_from_ordinal_exclusive,
                                        before: min(before, createdAt), visited: visited.union([id]))
        }
        return nil
    }

    private static func metadata(in url: URL) throws -> Metadata? {
        let handle = try FileHandle(forReadingFrom: url)
        let result: Metadata?
        do {
            var line = Data()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                if let newline = chunk.withUnsafeBytes({ bytes in bytes.firstIndex(of: 0x0A) }) {
                    line.append(chunk.subdata(in: 0..<newline))
                    break
                }
                line.append(chunk)
                guard line.count <= 4_194_304 else { throw CocoaError(.fileReadTooLarge) }
            }
            struct Header: Decodable { let type: String?; let id: String?; let timestamp: String? }
            struct Envelope: Decodable { let payload: Metadata }
            if line.isEmpty { result = nil }
            else {
                let header = try JSONDecoder().decode(Header.self, from: line)
                if header.type == "session_meta" { result = try JSONDecoder().decode(Envelope.self, from: line).payload }
                else if header.type == nil, header.id != nil, header.timestamp != nil {
                    result = try JSONDecoder().decode(Metadata.self, from: line)
                } else { result = nil }
            }
        } catch { try handle.close(); throw error }
        try handle.close()
        return result
    }

    private static func latestReading(in url: URL, size: Int, before: Date? = nil, ordinalLimit: UInt64? = nil) throws -> Reading? {
        guard size > 0 else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        let result: Reading?
        do { result = try scanBackwards(handle, size: size, before: before, ordinalLimit: ordinalLimit) }
        catch { try handle.close(); throw error }
        try handle.close()
        return result
    }

    private static func scanBackwards(_ handle: FileHandle, size: Int, before: Date?, ordinalLimit: UInt64?) throws -> Reading? {
        var offset = size
        var remainder = Data()
        var discardLastPart = true
        let decoder = JSONDecoder()
        let tokenMarker = Data("\"token_count\"".utf8)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        while offset > 0 {
            try Task.checkCancellation()
            let length = min(offset, 65_536)
            offset -= length
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: length), chunk.count == length else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var combined = chunk
            combined.append(remainder)
            let parts = lineRanges(in: combined)
            // The last fragment is either an unfinished append or part of an
            // oversized conversation line skipped in the next block.
            let candidates = discardLastPart ? parts.dropLast() : parts[...]
            let complete = offset > 0 ? candidates.dropFirst() : candidates[...]
            for range in complete.reversed() where !range.isEmpty {
                // Codex puts the event discriminator before its payload. Avoid
                // parsing conversation bodies while scanning a fork's prefix.
                let prefix = combined.subdata(in: range.lowerBound..<min(range.upperBound, range.lowerBound + 512))
                guard prefix.range(of: tokenMarker) != nil else { continue }
                let event = try decoder.decode(TokenEvent.self, from: combined.subdata(in: range))
                guard let usage = event.usage else { continue }
                if let ordinalLimit {
                    guard let ordinal = event.ordinal else { throw CocoaError(.coderInvalidValue) }
                    if ordinal >= ordinalLimit { continue }
                }
                guard let timestamp = event.timestamp,
                      let date = fractionalFormatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp) else {
                    throw CocoaError(.coderInvalidValue)
                }
                if let before, date > before { continue }
                guard usage.counts.values.allSatisfy({ $0 >= 0 }) else { throw CocoaError(.coderInvalidValue) }
                return Reading(counts: usage.counts, observedAt: date, ordinal: event.ordinal)
            }
            if parts.count > 1 { discardLastPart = false }
            if let first = parts.first, offset > 0, !discardLastPart {
                // Token-count events are small; large prompt/tool lines need not
                // accumulate in memory while searching for the latest event.
                if first.count > 4_194_304 { remainder = Data(); discardLastPart = true }
                else { remainder = combined.subdata(in: first) }
            } else { remainder = Data() }
        }
        return nil
    }

    private static func lineRanges(in data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { bytes in
            var ranges: [Range<Int>] = []
            var start = 0
            for index in bytes.indices where bytes[index] == 0x0A {
                ranges.append(start..<index)
                start = index + 1
            }
            ranges.append(start..<bytes.count)
            return ranges
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

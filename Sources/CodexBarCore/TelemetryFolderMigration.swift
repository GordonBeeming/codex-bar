import Foundation

/// Moves telemetry written by earlier versions out of `~/Documents`, so macOS stops asking for Documents access.
public struct TelemetryFolderMigration {
    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    /// Returns a message per failure. A failure never throws: capture must still write to the new default.
    public func run() -> [String] {
        guard let legacy = legacyFolder() else { return [] }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
            )
        } catch { return ["Couldn't read the old telemetry folder: \(error.localizedDescription)"] }

        let destination = TelemetryConfiguration.defaultDirectory(home: home)
        var warnings: [String] = []
        for entry in entries where Self.isTelemetryFile(entry) {
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                let target = destination.appending(path: entry.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    try merge(entry, into: target)
                } else {
                    try fileManager.moveItem(at: entry, to: target)
                }
            } catch {
                warnings.append("Couldn't move \(entry.lastPathComponent) out of the old telemetry folder: \(error.localizedDescription)")
            }
        }
        warnings.append(contentsOf: removeLegacyFolderIfEmpty(legacy))
        return warnings
    }

    /// True while a file the migration would still move is in the old folder, which means a previous attempt failed.
    public func hasPendingFiles() -> Bool {
        guard let legacy = legacyFolder(),
              let entries = try? fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
              ) else { return false }
        return entries.contains { entry in
            guard Self.isTelemetryFile(entry),
                  let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    /// The old folder, unless it's missing or a symbolic link: a link could point anywhere, and its target isn't ours to move out of.
    private func legacyFolder() -> URL? {
        let legacy = TelemetryConfiguration.legacyDefaultDirectory(home: home)
        guard let type = try? fileManager.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType,
              type == .typeDirectory else { return nil }
        return legacy
    }

    /// Appends the old file's complete lines, then deletes it. A trailing unterminated fragment is an unfinished
    /// record that the sink would discard itself, so it isn't carried over.
    /// The source is renamed to a name the migration doesn't match before appending, so a delete that fails afterwards
    /// can't cause the same lines to be appended again on the next launch.
    private func merge(_ source: URL, into target: URL) throws {
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
        }
        let incoming = try Data(contentsOf: source)
        guard let lastNewline = incoming.lastIndex(of: 0x0A) else {
            try fileManager.removeItem(at: source)
            return
        }
        let handle = try FileHandle(forUpdating: target)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            // Appending to an unfinished record would corrupt both lines; the sink repairs it on its next write.
            guard try handle.read(upToCount: 1)?.first == 0x0A else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: target.path,
                    NSLocalizedDescriptionKey: "the existing file ends in an unfinished record; it will be merged on a later launch"
                ])
            }
        }
        let claimed = source.appendingPathExtension("migrated")
        try fileManager.moveItem(at: source, to: claimed)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: incoming[incoming.startIndex...lastNewline])
            try handle.synchronize()
        } catch {
            // Undo any partial append and hand the file back for the next launch.
            try? handle.truncate(atOffset: size)
            try? fileManager.moveItem(at: claimed, to: source)
            throw error
        }
        try fileManager.removeItem(at: claimed)
    }

    private func removeLegacyFolderIfEmpty(_ legacy: URL) -> [String] {
        do {
            let remaining = try fileManager.contentsOfDirectory(atPath: legacy.path)
            guard remaining.allSatisfy({ $0 == ".DS_Store" }) else { return [] }
            for name in remaining { try fileManager.removeItem(at: legacy.appending(path: name)) }
            try fileManager.removeItem(at: legacy)
            return []
        } catch { return ["Couldn't remove the old telemetry folder: \(error.localizedDescription)"] }
    }

    static func isTelemetryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix(".jsonl") else { return false }
        for signal in TelemetrySignal.allCases {
            let prefix = "codexbar-\(signal.rawValue)-"
            guard name.hasPrefix(prefix) else { continue }
            let day = String(name.dropFirst(prefix.count).dropLast(".jsonl".count))
            guard day.count == 10 else { return false }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
        }
        return false
    }
}

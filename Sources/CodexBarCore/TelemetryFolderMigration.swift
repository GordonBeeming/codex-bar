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
        for entry in entries {
            guard let stage = Self.stage(of: entry) else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if stage == .migrated {
                    try fileManager.removeItem(at: entry)
                    continue
                }
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                let target = destination.appending(path: Self.originalName(of: entry))
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

    /// True while a file the migration would still move or finish merging is in the old folder, which means a previous
    /// attempt failed. A `.migrated` leftover is already merged and only needs deleting, so it doesn't count.
    public func hasPendingFiles() -> Bool {
        guard let legacy = legacyFolder() else { return false }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
            )
        } catch {
            // Unreadable (for example Documents access was denied) isn't empty: files may still be there to move.
            return true
        }
        return entries.contains { entry in
            guard let stage = Self.stage(of: entry), stage != .migrated,
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
    /// The source goes through `.merging` (append in progress) and `.migrated` (appended, only needs deleting). A crash
    /// leaves a name the next run recognizes: a `.merging` file is merged again, which can repeat a line that was
    /// already appended, and a `.migrated` file is just deleted.
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
        let merging = Self.stage(of: source) == .merging
            ? source : source.appendingPathExtension(Self.mergingExtension)
        if merging != source { try fileManager.moveItem(at: source, to: merging) }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: incoming[incoming.startIndex...lastNewline])
            try handle.synchronize()
        } catch {
            // Undo any partial append; the file keeps a name the next run picks up again.
            try? handle.truncate(atOffset: size)
            throw error
        }
        let migrated = merging.deletingPathExtension().appendingPathExtension(Self.migratedExtension)
        try fileManager.moveItem(at: merging, to: migrated)
        try fileManager.removeItem(at: migrated)
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

    private static let mergingExtension = "merging"
    private static let migratedExtension = "migrated"

    private enum Stage { case live, merging, migrated }

    private static func stage(of url: URL) -> Stage? {
        if isTelemetryFile(url) { return .live }
        guard isTelemetryFile(url.deletingPathExtension()) else { return nil }
        switch url.pathExtension {
        case mergingExtension: return .merging
        case migratedExtension: return .migrated
        default: return nil
        }
    }

    private static func originalName(of url: URL) -> String {
        stage(of: url) == .live ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
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

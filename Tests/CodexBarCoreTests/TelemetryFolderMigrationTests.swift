import XCTest
@testable import CodexBarCore

private final class UndeletableFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: URL.path])
    }
}

private final class UnreadableFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }
}

final class TelemetryFolderMigrationTests: XCTestCase {
    private var home: URL!
    private var legacy: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "codexbar-home-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        legacy = TelemetryConfiguration.legacyDefaultDirectory(home: home)
        destination = TelemetryConfiguration.defaultDirectory(home: home)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    func testMovesMatchingFilesAndRemovesEmptyLegacyFolder() throws {
        try write("codexbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        try write("codexbar-logs-2026-10-11.jsonl", "l\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try read("codexbar-metrics-2026-10-11.jsonl", in: destination), "m\n")
        XCTAssertEqual(try read("codexbar-logs-2026-10-11.jsonl", in: destination), "l\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCreatesDestinationWithPrivatePermissions() throws {
        try write("codexbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testLeavesOtherFilesAndKeepsFolderWhenNotEmpty() throws {
        try write("codexbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        try write("notes.txt", "mine", in: legacy)
        try write("codexbar-metrics-2026-10-11.jsonl.bak", "bak", in: legacy)
        try write("codexbar-metrics-2026-13-45.jsonl", "bad date", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read("notes.txt", in: legacy), "mine")
        XCTAssertEqual(try read("codexbar-metrics-2026-10-11.jsonl.bak", in: legacy), "bak")
        XCTAssertEqual(try read("codexbar-metrics-2026-13-45.jsonl", in: legacy), "bad date")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "notes.txt").path))
        XCTAssertEqual(try read("codexbar-metrics-2026-10-11.jsonl", in: destination), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appending(path: "codexbar-metrics-2026-10-11.jsonl").path))
    }

    func testIgnoresDSStoreWhenDecidingIfLegacyFolderIsEmpty() throws {
        try write("codexbar-logs-2026-10-11.jsonl", "l\n", in: legacy)
        try write(".DS_Store", "x", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testKeepsDSStoreWhenOtherFilesRemain() throws {
        try write("notes.txt", "mine", in: legacy)
        try write(".DS_Store", "x", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(".DS_Store", in: legacy), "x")
        XCTAssertEqual(try read("notes.txt", in: legacy), "mine")
    }

    func testSameNameFileIsAppendedNotOverwritten() throws {
        let name = "codexbar-metrics-2026-10-11.jsonl"
        try write(name, "new1\nnew2\n", in: destination)
        try write(name, "old1\nold2\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try read(name, in: destination), "new1\nnew2\nold1\nold2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMergeAppendsOnlyCompleteLines() throws {
        let name = "codexbar-logs-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old1\nunfinished", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(name, in: destination), "new\nold1\n")
    }

    func testMergeIntoUnterminatedDestinationLeavesLegacyFileInPlace() throws {
        let name = "codexbar-logs-2026-10-11.jsonl"
        try write(name, "new-without-newline", in: destination)
        try write(name, "old\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try read(name, in: destination), "new-without-newline")
        XCTAssertEqual(try read(name, in: legacy), "old\n")
    }

    func testSymbolicLinkedLegacyRootIsNotFollowed() throws {
        let elsewhere = home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try write("codexbar-metrics-2026-10-11.jsonl", "m\n", in: elsewhere)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: elsewhere)
        let migration = TelemetryFolderMigration(home: home)

        XCTAssertEqual(migration.run(), [])
        XCTAssertFalse(migration.hasPendingFiles())
        XCTAssertEqual(try read("codexbar-metrics-2026-10-11.jsonl", in: elsewhere), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPendingFilesOnlyCountEligibleTelemetryFiles() throws {
        let migration = TelemetryFolderMigration(home: home)
        XCTAssertFalse(migration.hasPendingFiles())
        try write("notes.txt", "mine", in: legacy)
        XCTAssertFalse(migration.hasPendingFiles())
        try write("codexbar-logs-2026-10-11.jsonl", "l\n", in: legacy)
        XCTAssertTrue(migration.hasPendingFiles())
    }

    func testFailedDeleteAfterAppendDoesNotAppendAgainOnRetry() throws {
        let name = "codexbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old\n", in: legacy)

        let failing = TelemetryFolderMigration(home: home, fileManager: UndeletableFileManager())
        XCTAssertEqual(failing.run().count, 1)
        XCTAssertFalse(failing.hasPendingFiles())
        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
    }

    func testUnreadableLegacyFolderCountsAsPendingSoItIsRetried() throws {
        try write("codexbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        let migration = TelemetryFolderMigration(home: home, fileManager: UnreadableFileManager())

        XCTAssertEqual(migration.run().count, 1)
        XCTAssertTrue(migration.hasPendingFiles())
    }

    func testNoLegacyFolderIsANoOp() {
        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDoesNotMoveSymbolicLinks() throws {
        let outside = home.appending(path: "outside.jsonl")
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: legacy.appending(path: "codexbar-metrics-2026-10-11.jsonl"), withDestinationURL: outside
        )

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "codexbar-metrics-2026-10-11.jsonl").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: legacy.appending(path: "codexbar-metrics-2026-10-11.jsonl").path
        ))
    }

    private func write(_ name: String, _ content: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: directory.appending(path: name))
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }
}

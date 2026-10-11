import Foundation
import Synchronization

public struct CreditsSnapshot: Decodable, Sendable, Equatable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
}

public struct SpendControlSnapshot: Decodable, Sendable, Equatable {
    public let limit: String
    public let used: String
    public let remainingPercent: Double
    public let resetsAt: TimeInterval
}

public struct ResetCredit: Decodable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let resetType: String
    public let grantedAt: TimeInterval
    public let expiresAt: TimeInterval?
    public let title: String?
    public let description: String?
}

public struct ResetCreditsSummary: Decodable, Sendable, Equatable {
    public let availableCount: Int
    public let credits: [ResetCredit]?
}

public struct AccountTokenUsage: Decodable, Sendable, Equatable {
    public struct Summary: Decodable, Sendable, Equatable {
        public let lifetimeTokens: Int64?
        public let peakDailyTokens: Int64?
        public let currentStreakDays: Int64?
        public let longestStreakDays: Int64?
        public let longestRunningTurnSec: Int64?
    }
    public struct DailyBucket: Decodable, Sendable, Equatable {
        public let startDate: String
        public let tokens: Int64
    }
    public let summary: Summary
    public let dailyUsageBuckets: [DailyBucket]?
}

public struct TelemetryConfiguration: Equatable, Sendable {
    public static let unlimitedRetentionDays = 0
    public let enabled: Bool
    public let intervalMinutes: Int
    public let retentionDays: Int
    public let directory: URL

    public init(enabled: Bool = false, intervalMinutes: Int = 5, retentionDays: Int = 90, directory: URL) {
        self.enabled = enabled
        self.intervalMinutes = min(max(intervalMinutes, 1), 1_440)
        self.retentionDays = Self.normalizedRetentionDays(retentionDays)
        self.directory = directory
    }

    public static func normalizedRetentionDays(_ days: Int) -> Int {
        days == unlimitedRetentionDays ? unlimitedRetentionDays : min(max(days, 1), 3_650)
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/CodexBar Telemetry")
    }
}

public enum TelemetrySignal: String, Sendable, CaseIterable {
    case metrics, logs
}

public final class TelemetryActivity: Sendable {
    private let enabled = Mutex(true)
    private let retentionDays: Mutex<Int?>

    public init(retentionDays: Int? = nil) {
        self.retentionDays = Mutex(retentionDays.map(TelemetryConfiguration.normalizedRetentionDays))
    }
    public func updateRetentionDays(_ days: Int) {
        retentionDays.withLock { $0 = TelemetryConfiguration.normalizedRetentionDays(days) }
    }
    public func currentRetentionDays(fallback: Int) -> Int {
        retentionDays.withLock { $0 ?? fallback }
    }
    public func stop() { enabled.withLock { $0 = false } }
    public func check() throws {
        try Task.checkCancellation()
        guard enabled.withLock({ $0 }) else { throw CancellationError() }
    }
}

public protocol TelemetrySink: Sendable {
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int, activity: TelemetryActivity?) async throws
    func exportWarnings() async -> [String]
}

public extension TelemetrySink {
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int) async throws {
        try await export(data, signal: signal, at: date, retentionDays: retentionDays, activity: nil)
    }
    func exportWarnings() async -> [String] { [] }
}

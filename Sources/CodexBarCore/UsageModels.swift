import Foundation

public enum Severity: Int, Sendable, Comparable {
    case normal
    case warning
    case critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct UsageLimit: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let percent: Double
    public let resetsAt: Date?
    public let windowDurationMinutes: Int?

    public init(
        id: String,
        name: String,
        percent: Double,
        resetsAt: Date?,
        windowDurationMinutes: Int?
    ) {
        self.id = id
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }

    public var defaultSeverity: Severity {
        if percent >= 90 {
            return .critical
        }
        if percent >= 75 {
            return .warning
        }
        return .normal
    }

    public var group: String? {
        switch windowDurationMinutes {
        case 300: return "session"
        case 10_080: return "weekly"
        default: return nil
        }
    }

    public var celebrationKey: String { id }
}

public struct RateLimitWindow: Decodable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: TimeInterval?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct RateLimitBucket: Decodable, Sendable, Equatable {
    public let limitId: String
    public let limitName: String?
    public let planType: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?

    public init(
        limitId: String,
        limitName: String?,
        planType: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
    }
}

public struct RateLimitsResult: Decodable, Sendable, Equatable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?

    public init(rateLimits: RateLimitBucket?, rateLimitsByLimitId: [String: RateLimitBucket]?) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }
}

public struct AccountInfo: Decodable, Sendable, Equatable {
    public let type: String
    public let planType: String?

    public init(type: String, planType: String?) {
        self.type = type
        self.planType = planType
    }
}

public struct AccountReadResult: Decodable, Sendable, Equatable {
    public let account: AccountInfo?
    public let requiresOpenaiAuth: Bool

    public init(account: AccountInfo?, requiresOpenaiAuth: Bool) {
        self.account = account
        self.requiresOpenaiAuth = requiresOpenaiAuth
    }
}

public struct CodexProbeResult: Sendable, Equatable {
    public let account: AccountReadResult
    public let rateLimits: RateLimitsResult?
    public let rateLimitsError: RPCError?

    public init(account: AccountReadResult, rateLimits: RateLimitsResult?, rateLimitsError: RPCError?) {
        self.account = account
        self.rateLimits = rateLimits
        self.rateLimitsError = rateLimitsError
    }
}

public enum UsageLimitMapper {
    public static func limits(from result: RateLimitsResult) -> [UsageLimit] {
        let buckets = orderedBuckets(from: result)
        let showBucketName = buckets.count > 1

        return buckets.flatMap { bucket in
            let bucketName = bucket.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? bucket.limitId
            return [
                bucket.primary.map {
                    makeLimit(
                        bucket: bucket,
                        bucketName: bucketName,
                        role: "primary",
                        window: $0,
                        showBucketName: showBucketName
                    )
                },
                bucket.secondary.map {
                    makeLimit(
                        bucket: bucket,
                        bucketName: bucketName,
                        role: "secondary",
                        window: $0,
                        showBucketName: showBucketName
                    )
                }
            ].compactMap { $0 }
        }
    }

    public static func planType(from result: RateLimitsResult, account: AccountInfo?) -> String? {
        orderedBuckets(from: result).compactMap(\.planType).first ?? account?.planType
    }

    private static func orderedBuckets(from result: RateLimitsResult) -> [RateLimitBucket] {
        if let byId = result.rateLimitsByLimitId, !byId.isEmpty {
            return byId.keys.sorted().compactMap { byId[$0] }
        }
        return result.rateLimits.map { [$0] } ?? []
    }

    private static func makeLimit(
        bucket: RateLimitBucket,
        bucketName: String,
        role: String,
        window: RateLimitWindow,
        showBucketName: Bool
    ) -> UsageLimit {
        let windowName = displayName(for: window, role: role)
        let name = showBucketName ? "\(windowName) — \(humanize(bucketName))" : windowName
        return UsageLimit(
            id: "\(bucket.limitId).\(role)",
            name: name,
            percent: min(max(window.usedPercent, 0), 100),
            resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowDurationMinutes: window.windowDurationMins
        )
    }

    private static func displayName(for window: RateLimitWindow, role: String) -> String {
        switch window.windowDurationMins {
        case 300:
            return "Session (5h)"
        case 10_080:
            return "Weekly"
        case let minutes?:
            if minutes.isMultiple(of: 1_440) {
                return "\(minutes / 1_440)-day window"
            }
            if minutes.isMultiple(of: 60) {
                return "\(minutes / 60)-hour window"
            }
            return "\(minutes)-minute window"
        case nil:
            return role == "primary" ? "Primary" : "Secondary"
        }
    }

    private static func humanize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public enum UsageWindow {
    public static func paceFraction(for limit: UsageLimit, now: Date = Date()) -> Double? {
        guard
            let resetsAt = limit.resetsAt,
            let durationMinutes = limit.windowDurationMinutes,
            durationMinutes > 0
        else {
            return nil
        }

        let duration = TimeInterval(durationMinutes * 60)
        let startedAt = resetsAt.addingTimeInterval(-duration)
        return min(max(now.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    public static func isAheadOfPace(
        for limit: UsageLimit,
        now: Date = Date(),
        marginPercent: Double = 0
    ) -> Bool {
        guard let pace = paceFraction(for: limit, now: now) else { return false }
        let tolerance = 0.0001
        return limit.percent - pace * 100 > marginPercent + tolerance
    }
}

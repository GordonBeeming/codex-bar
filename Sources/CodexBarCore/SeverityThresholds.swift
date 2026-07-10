public struct SeverityThresholds: Sendable, Equatable {
    public var useDefaults: Bool

    private var storedWarningPercent: Double
    public var warningPercent: Double {
        get { storedWarningPercent }
        set { storedWarningPercent = Self.clamp(newValue) }
    }

    private var storedCriticalPercent: Double
    public var criticalPercent: Double {
        get { storedCriticalPercent }
        set { storedCriticalPercent = Self.clamp(newValue) }
    }

    public init(useDefaults: Bool = true, warningPercent: Double = 75, criticalPercent: Double = 90) {
        self.useDefaults = useDefaults
        self.storedWarningPercent = Self.clamp(warningPercent)
        self.storedCriticalPercent = Self.clamp(criticalPercent)
    }

    public func resolve(for limit: UsageLimit) -> Severity {
        let warning = useDefaults ? 75 : warningPercent
        let critical = useDefaults ? 90 : max(warningPercent, criticalPercent)
        if limit.percent >= critical { return .critical }
        if limit.percent >= warning { return .warning }
        return .normal
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }
}

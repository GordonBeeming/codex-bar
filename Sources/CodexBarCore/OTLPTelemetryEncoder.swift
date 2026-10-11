import Foundation

// Only the OTLP fields emitted by CodexBar are modelled here. Int64 values use
// decimal strings, as required by OTLP's JSON encoding.
public enum OTLPTelemetryEncoder {
    struct Attribute: Encodable, Sendable {
        let key: String
        let value: Value

        init(_ key: String, _ value: String) { self.key = key; self.value = Value(stringValue: value) }
        init(_ key: String, _ value: Bool) { self.key = key; self.value = Value(boolValue: value) }
        init(_ key: String, _ value: Int) { self.key = key; self.value = Value(intValue: String(value)) }
        init(_ key: String, _ value: Double) { self.key = key; self.value = Value(doubleValue: value) }
    }

    struct Value: Encodable, Sendable {
        var stringValue: String?
        var boolValue: Bool?
        var intValue: String?
        var doubleValue: Double?
    }

    private struct Resource: Encodable { let attributes: [Attribute] }
    private struct Scope: Encodable {
        let name = "com.gordonbeeming.CodexBar.telemetry"
        let version = "1"
    }
    private struct Point: Encodable {
        let attributes: [Attribute]
        let timeUnixNano: String
        let asDouble: Double?
        let asInt: String?
    }
    private struct Gauge: Encodable { let dataPoints: [Point] }
    private struct Metric: Encodable {
        let name: String
        let unit: String
        let gauge: Gauge
    }
    private struct ScopeMetrics: Encodable { let scope = Scope(); let metrics: [Metric] }
    private struct ResourceMetrics: Encodable { let resource: Resource; let scopeMetrics: [ScopeMetrics] }
    private struct MetricsData: Encodable { let resourceMetrics: [ResourceMetrics] }

    struct Event: Sendable {
        let name: String
        let attributes: [Attribute]
    }
    private struct LogRecord: Encodable {
        let timeUnixNano: String
        let observedTimeUnixNano: String
        let severityNumber = 9
        let severityText = "INFO"
        let body: Value
        let attributes: [Attribute]
    }
    private struct ScopeLogs: Encodable { let scope = Scope(); let logRecords: [LogRecord] }
    private struct ResourceLogs: Encodable { let resource: Resource; let scopeLogs: [ScopeLogs] }
    private struct LogsData: Encodable { let resourceLogs: [ResourceLogs] }

    public static func metrics(
        result: RateLimitsResult?, planType: String?, observedAt: Date?, capturedAt: Date,
        serviceVersion: String, localTokens: LocalTokenTotals? = nil, accountTokens: AccountTokenUsage? = nil
    ) throws -> Data {
        var points: [String: (unit: String, points: [Point])] = [:]
        let timestamp = try nanos(capturedAt)
        let common: [Attribute] = [
            Attribute("codex.source", "account/rateLimits/read")
        ]
        func add(_ name: String, _ value: Double, unit: String = "1", attributes: [Attribute] = []) {
            guard value.isFinite else { return }
            let point = Point(attributes: common + attributes, timeUnixNano: timestamp, asDouble: value, asInt: nil)
            if points[name] == nil { points[name] = (unit, []) }
            points[name]?.points.append(point)
        }
        if let observedAt, result != nil { add("codex.usage.observation_time", observedAt.timeIntervalSince1970, unit: "s") }

        for (id, bucket) in result?.orderedBuckets ?? [] {
            let attributes = [Attribute("codex.bucket.id", id)]
            add("codex.usage.bucket_observed", 1, attributes: attributes)
            for (role, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                var windowAttributes = attributes + [Attribute("codex.window", role)]
                if let minutes = window.windowDurationMins {
                    windowAttributes.append(Attribute("codex.window.duration_minutes", minutes))
                }
                add("codex.usage.used_percent", window.usedPercent, unit: "%", attributes: windowAttributes)
                if let reset = window.resetsAt {
                    add("codex.usage.reset_time", reset, unit: "s", attributes: windowAttributes)
                }
            }
            if let credits = bucket.credits {
                add("codex.credits.has_credits", credits.hasCredits ? 1 : 0, attributes: attributes)
                add("codex.credits.unlimited", credits.unlimited ? 1 : 0, attributes: attributes)
                if let balance = credits.balance, let value = Double(balance) {
                    add("codex.credits.balance", value, attributes: attributes)
                }
            }
            if let reached = bucket.spendControlReached {
                add("codex.spend_control.reached", reached ? 1 : 0, attributes: attributes)
            }
            if let spend = bucket.individualLimit {
                add("codex.spend_control.remaining_percent", spend.remainingPercent, unit: "%", attributes: attributes)
                add("codex.spend_control.reset_time", spend.resetsAt, unit: "s", attributes: attributes)
                if let limit = Double(spend.limit) { add("codex.spend_control.limit", limit, attributes: attributes) }
                if let used = Double(spend.used) { add("codex.spend_control.used", used, attributes: attributes) }
            }
        }
        if let allowed = result?.ordinaryUsageAllowed {
            add("codex.usage.ordinary_allowed", allowed ? 1 : 0)
        }
        if let resets = result?.rateLimitResetCredits {
            add("codex.reset_credits.available", Double(resets.availableCount))
            for credit in resets.credits ?? [] {
                let attributes: [Attribute] = [.init("codex.reset_credit.id", credit.id)]
                add("codex.reset_credit.observed", 1, attributes: attributes)
                add("codex.reset_credit.granted_at", credit.grantedAt, unit: "s", attributes: attributes)
                if let expiry = credit.expiresAt { add("codex.reset_credit.expires_at", expiry, unit: "s", attributes: attributes) }
            }
        }
        if let localTokens {
            let attributes: [Attribute] = [
                .init("codex.source", "local_session_files"),
                .init("codex.token.scope", "retained_local_sessions")
            ]
            if let observedAt = localTokens.latestObservation {
                points["codex.tokens.observation_time"] = ("s", [Point(
                    attributes: attributes, timeUnixNano: timestamp,
                    asDouble: observedAt.timeIntervalSince1970, asInt: nil
                )])
            }
            points["codex.tokens.sessions"] = ("{session}", [Point(
                attributes: attributes, timeUnixNano: timestamp, asDouble: nil, asInt: String(localTokens.sessionCount)
            )])
            points["codex.tokens.files_skipped"] = ("{file}", [Point(
                attributes: attributes, timeUnixNano: timestamp, asDouble: nil, asInt: String(localTokens.skippedFiles)
            )])
            points["codex.tokens.sessions_reporting"] = ("{session}", localTokens.counts.keys.sorted().compactMap { kind in
                guard let count = localTokens.counts[kind] else { return nil }
                return Point(attributes: attributes + [.init("codex.token.kind", kind)], timeUnixNano: timestamp,
                             asDouble: nil, asInt: String(count.sessionsReporting))
            })
            for (kind, count) in localTokens.counts {
                points["codex.tokens.\(kind)"] = ("{token}", [Point(
                    attributes: attributes,
                    timeUnixNano: timestamp, asDouble: nil, asInt: String(count.value)
                )])
            }
        }
        if let accountTokens {
            let attributes = [Attribute("codex.source", "account/usage/read"), Attribute("codex.token.scope", "account")]
            let summary = accountTokens.summary
            let values: [(String, Int64?, String)] = [
                ("lifetime", summary.lifetimeTokens, "{token}"), ("peak_daily", summary.peakDailyTokens, "{token}"),
                ("current_streak", summary.currentStreakDays, "d"), ("longest_streak", summary.longestStreakDays, "d"),
                ("longest_running_turn", summary.longestRunningTurnSec, "s")
            ]
            for (name, value, unit) in values {
                guard let value, value >= 0 else { continue }
                points["codex.account.\(name)"] = (unit, [Point(attributes: attributes, timeUnixNano: timestamp,
                                                             asDouble: nil, asInt: String(value))])
            }
            let daily = try (accountTokens.dailyUsageBuckets ?? []).filter { $0.tokens >= 0 }.compactMap { bucket -> Point? in
                let formatter = ISO8601DateFormatter()
                guard let date = formatter.date(from: bucket.startDate)
                    ?? formatter.date(from: bucket.startDate + "T00:00:00Z") else { return nil }
                return Point(attributes: attributes, timeUnixNano: try nanos(date), asDouble: nil, asInt: String(bucket.tokens))
            }
            if !daily.isEmpty { points["codex.account.daily_tokens"] = ("{token}", daily) }
        }
        let metrics = points.keys.sorted().compactMap { name -> Metric? in
            guard let entry = points[name] else { return nil }
            return Metric(name: name, unit: entry.unit, gauge: Gauge(dataPoints: entry.points))
        }
        return try encode(MetricsData(resourceMetrics: [ResourceMetrics(
            resource: resource(serviceVersion), scopeMetrics: [ScopeMetrics(metrics: metrics)]
        )]))
    }

    static func sampleDetails(
        result: RateLimitsResult, planType: String?, at date: Date, serviceVersion: String,
        accountTokens: AccountTokenUsage? = nil
    ) throws -> Data {
        var events: [Event] = []
        for (id, bucket) in result.orderedBuckets {
            var attributes: [Attribute] = [.init("codex.bucket.id", id)]
            if let plan = bucket.planType ?? planType { attributes.append(.init("codex.plan_type", plan)) }
            if let name = bucket.limitName { attributes.append(.init("codex.bucket.name", name)) }
            if let model = bucket.normalModelSlug { attributes.append(.init("codex.model", model)) }
            if let reached = bucket.rateLimitReachedType { attributes.append(.init("codex.rate_limit_reached_type", reached)) }
            if let balance = bucket.credits?.balance { attributes.append(.init("codex.balance.raw", balance)) }
            if let spend = bucket.individualLimit {
                attributes += [.init("codex.spend_control.limit", spend.limit), .init("codex.spend_control.used", spend.used)]
            }
            events.append(.init(name: "codex.usage.details", attributes: attributes))
        }
        for credit in result.rateLimitResetCredits?.credits ?? [] {
            var attributes: [Attribute] = [
                .init("codex.reset_credit.id", credit.id), .init("codex.reset_credit.status", credit.status),
                .init("codex.reset_credit.reset_type", credit.resetType)
            ]
            if let title = credit.title { attributes.append(.init("codex.reset_credit.title", title)) }
            if let description = credit.description { attributes.append(.init("codex.reset_credit.description", description)) }
            events.append(.init(name: "codex.reset_credit.details", attributes: attributes))
        }
        for bucket in accountTokens?.dailyUsageBuckets ?? [] {
            events.append(.init(name: "codex.account.daily_usage", attributes: [
                .init("codex.source", "account/usage/read"), .init("codex.usage.start_date", bucket.startDate),
                .init("codex.usage.tokens", Int(bucket.tokens))
            ]))
        }
        return try logs(events, at: date, serviceVersion: serviceVersion)
    }

    static func logs(_ events: [Event], at date: Date, serviceVersion: String) throws -> Data {
        let timestamp = try nanos(date)
        let records = events.map {
            LogRecord(timeUnixNano: timestamp, observedTimeUnixNano: timestamp,
                      body: Value(stringValue: $0.name), attributes: $0.attributes)
        }
        return try encode(LogsData(resourceLogs: [ResourceLogs(
            resource: resource(serviceVersion), scopeLogs: [ScopeLogs(logRecords: records)]
        )]))
    }

    private static func resource(_ version: String) -> Resource {
        Resource(attributes: [Attribute("service.name", "CodexBar"), Attribute("service.version", version)])
    }

    private static func nanos(_ date: Date) throws -> String {
        let value = date.timeIntervalSince1970 * 1_000_000_000
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else {
            throw CocoaError(.coderInvalidValue)
        }
        return String(UInt64(value))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

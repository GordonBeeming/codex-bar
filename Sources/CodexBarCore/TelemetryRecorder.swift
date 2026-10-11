import Foundation

public actor TelemetryRecorder {
    private let sink: any TelemetrySink
    private var retentionDays: Int { activity.currentRetentionDays(fallback: 90) }
    private let serviceVersion: String
    private var accountScope: String?
    private var availableCount: Int?
    private var creditStatuses: [String: String] = [:]
    private var observingCredits = false
    private var creditWaiters: [CheckedContinuation<Void, Never>] = []
    private let activity: TelemetryActivity
    private var dailyBuckets: [String: Int64] = [:]
    private var dailyAccountScope: String?

    public init(sink: any TelemetrySink, retentionDays: Int, serviceVersion: String) {
        self.sink = sink
        self.activity = TelemetryActivity(retentionDays: retentionDays)
        self.serviceVersion = serviceVersion
    }

    public func recordSample(
        result: RateLimitsResult?, planType: String?, observedAt: Date?, at date: Date,
        localTokens: LocalTokenTotals? = nil, accountTokens: AccountTokenUsage? = nil
    ) async throws {
        try activity.check()
        let scope = result?.accountId ?? planType ?? dailyAccountScope
        if scope != dailyAccountScope { dailyBuckets = [:] }
        let today = String(ISO8601DateFormatter().string(from: date).prefix(10))
        let changedBuckets = accountTokens?.dailyUsageBuckets?.filter {
            String($0.startDate.prefix(10)) == today || dailyBuckets[$0.startDate] != $0.tokens
        }
        let filteredTokens = accountTokens.map { AccountTokenUsage(summary: $0.summary, dailyUsageBuckets: changedBuckets) }
        let data = try OTLPTelemetryEncoder.metrics(result: result, planType: planType,
                                                  observedAt: observedAt, capturedAt: date,
                                                  serviceVersion: serviceVersion, localTokens: localTokens, accountTokens: filteredTokens)
        try await sink.export(data, signal: .metrics, at: date, retentionDays: retentionDays, activity: activity)
        try activity.check()
        if let result {
            let details = try OTLPTelemetryEncoder.sampleDetails(result: result, planType: planType,
                                                                at: date, serviceVersion: serviceVersion, accountTokens: filteredTokens)
            try await sink.export(details, signal: .logs, at: date, retentionDays: retentionDays, activity: activity)
        }
        for bucket in changedBuckets ?? [] { dailyBuckets[bucket.startDate] = bucket.tokens }
        dailyAccountScope = scope
    }

    public nonisolated func updateRetentionDays(_ days: Int) { activity.updateRetentionDays(days) }
    public nonisolated func stop() { activity.stop() }
    public func exportWarnings() async -> [String] { await sink.exportWarnings() }

    public func observeResetCredits(result: RateLimitsResult, planType: String?, at date: Date) async throws {
        await acquireCreditObservation()
        defer { releaseCreditObservation() }
        try activity.check()
        let scope = result.accountId ?? planType ?? accountScope
        let changedAccount = accountScope != scope
        let previousCount = changedAccount ? nil : availableCount
        var statuses = changedAccount ? [:] : creditStatuses
        guard let summary = result.rateLimitResetCredits else { return }
        var events: [OTLPTelemetryEncoder.Event] = []
        var common = [OTLPTelemetryEncoder.Attribute("codex.source", "account/rateLimits/read")]
        if let planType { common.append(.init("codex.plan_type", planType)) }
        if summary.availableCount != previousCount {
            var attributes = common + [.init("codex.reset_credits.available_count", summary.availableCount)]
            if let previousCount { attributes.append(.init("codex.reset_credits.previous_count", previousCount)) }
            events.append(.init(name: "codex.reset_credits.availability_observed", attributes: attributes))
        }
        for credit in summary.credits ?? [] {
            let previous = statuses[credit.id]
            guard previous != credit.status else { continue }
            var attributes = common + [
                .init("codex.reset_credit.id", credit.id),
                .init("codex.reset_credit.status", credit.status),
                .init("codex.reset_credit.reset_type", credit.resetType),
                .init("codex.reset_credit.granted_at", credit.grantedAt),
                .init("codex.reset_credit.first_observation", previous == nil)
            ]
            if let previous { attributes.append(.init("codex.reset_credit.previous_status", previous)) }
            if let expiry = credit.expiresAt { attributes.append(.init("codex.reset_credit.expires_at", expiry)) }
            if let title = credit.title { attributes.append(.init("codex.reset_credit.title", title)) }
            if let description = credit.description { attributes.append(.init("codex.reset_credit.description", description)) }
            let eventName: String
            switch credit.status {
            case "available": eventName = "codex.reset_credit.available"
            case "redeeming": eventName = "codex.reset_credit.redeeming"
            case "redeemed": eventName = previous == nil ? "codex.reset_credit.status_observed" : "codex.reset_credit.redeemed"
            default: eventName = "codex.reset_credit.status_observed"
            }
            events.append(.init(name: eventName, attributes: attributes))
            statuses[credit.id] = credit.status
        }
        if !events.isEmpty {
            let data = try OTLPTelemetryEncoder.logs(events, at: date, serviceVersion: serviceVersion)
            try activity.check()
            try await sink.export(data, signal: .logs, at: date, retentionDays: retentionDays, activity: activity)
        }
        // Missing detail rows are not evidence of redemption: the backend can
        // return a capped list or only the available count.
        accountScope = scope
        availableCount = summary.availableCount
        creditStatuses = statuses
    }

    private func acquireCreditObservation() async {
        if observingCredits {
            await withCheckedContinuation { creditWaiters.append($0) }
        } else { observingCredits = true }
    }

    private func releaseCreditObservation() {
        if creditWaiters.isEmpty { observingCredits = false }
        else { creditWaiters.removeFirst().resume() }
    }
}

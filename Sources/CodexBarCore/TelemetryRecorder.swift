import Foundation

/// Everything tracking carries between launches.
struct TelemetryState: Codable, Sendable, Equatable {
    var scan: SessionScanState?
    /// `nil` until the first successful usage read since tracking started.
    var limits: [String: ObservedLimit]?
    var perks: ObservedPerks?
    /// `false` from a new baseline until `bar.tracking.started` is written. The baseline is
    /// kept meanwhile, so a failed write delays the event without losing tokens.
    var startAnnounced: Bool?
}

public actor TelemetryRecorder {
    private let sink: any TelemetrySink
    private var retentionDays: Int { activity.currentRetentionDays(fallback: 90) }
    private let serviceVersion: String
    private let intervalMinutes: Int
    private let stateURL: URL
    private let scanner: SessionTokenScanner
    private var state: TelemetryState?
    private var warnings: [String] = []
    private var accountScope: String?
    private var availableCount: Int?
    private var creditStatuses: [String: String] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let activity: TelemetryActivity
    private var dailyBuckets: [String: Int64] = [:]
    private var dailyAccountScope: String?

    public init(
        sink: any TelemetrySink, retentionDays: Int, serviceVersion: String,
        intervalMinutes: Int = 5, stateURL: URL, scanner: SessionTokenScanner
    ) {
        self.sink = sink
        self.activity = TelemetryActivity(retentionDays: retentionDays)
        self.serviceVersion = serviceVersion
        self.intervalMinutes = intervalMinutes
        self.stateURL = stateURL
        self.scanner = scanner
    }

    public static var defaultStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/CodexBar/telemetry-state.json")
    }

    /// Forgets the token baseline and observations, so the next start counts from a new
    /// start time and Bar UI reads it as a restart rather than a drop. Stop every recorder
    /// using `url` first: `stop()` waits for an in-flight state write.
    public static func discardState(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func recordSample(
        result: RateLimitsResult?, planType: String?, observedAt: Date?, at date: Date,
        accountTokens: AccountTokenUsage? = nil
    ) async throws {
        await acquire()
        defer { release() }
        try activity.check()
        var current = loadState()
        var events: [OTLPTelemetryEncoder.Event] = []

        // Tokens are cumulative and lose nothing if a later write fails, so the scan's
        // progress is kept regardless.
        if var scan = current.scan {
            do {
                for failure in try scanner.scan(&scan) {
                    warnings.append("Couldn't read Codex session \(failure.file): \(failure.message)")
                }
                current.scan = scan
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Couldn't read Codex sessions: \(error.localizedDescription)") }
        } else {
            current.scan = try scanner.baseline(now: date)
            current.limits = nil
            current.startAnnounced = false
        }
        if current.startAnnounced == false {
            events.append(BarEvents.trackingStarted(intervalMinutes: intervalMinutes))
        }
        var progress = loadState()
        progress.scan = current.scan
        progress.limits = current.limits
        progress.startAnnounced = current.startAnnounced
        if progress != loadState() { try save(progress) }

        var limits = current.limits
        if let result {
            let barLimits = BarLimit.limits(from: result)
            events += BarEvents.limitEvents(previous: current.limits, current: barLimits)
            limits = BarEvents.observed(barLimits)
        }

        let scope = result?.accountId ?? planType ?? dailyAccountScope
        if scope != dailyAccountScope { dailyBuckets = [:] }
        let today = String(ISO8601DateFormatter().string(from: date).prefix(10))
        let changedBuckets = accountTokens?.dailyUsageBuckets?.filter {
            String($0.startDate.prefix(10)) == today || dailyBuckets[$0.startDate] != $0.tokens
        }
        let filteredTokens = accountTokens.map { AccountTokenUsage(summary: $0.summary, dailyUsageBuckets: changedBuckets) }
        let data = try OTLPTelemetryEncoder.metrics(result: result, planType: planType,
                                                  observedAt: observedAt, capturedAt: date,
                                                  serviceVersion: serviceVersion, tokens: current.scan, accountTokens: filteredTokens)
        try await sink.export(data, signal: .metrics, at: date, retentionDays: retentionDays, activity: activity)
        try activity.check()
        if let result {
            events += OTLPTelemetryEncoder.sampleDetails(result: result, planType: planType, accountTokens: filteredTokens)
        }
        if !events.isEmpty {
            let logs = try OTLPTelemetryEncoder.logs(events, at: date, serviceVersion: serviceVersion)
            try await sink.export(logs, signal: .logs, at: date, retentionDays: retentionDays, activity: activity)
        }
        // Events are diffs against the last observation; advancing it only after the write
        // means a failed write re-emits them on the next capture instead of losing them.
        var saved = loadState()
        saved.limits = limits
        if saved.startAnnounced == false { saved.startAnnounced = true }
        try save(saved)
        for bucket in changedBuckets ?? [] { dailyBuckets[bucket.startDate] = bucket.tokens }
        dailyAccountScope = scope
    }

    public nonisolated func updateRetentionDays(_ days: Int) { activity.updateRetentionDays(days) }
    public nonisolated func stop() { activity.stop() }

    public func exportWarnings() async -> [String] {
        let own = warnings
        warnings = []
        return own + (await sink.exportWarnings())
    }

    public func observeResetCredits(result: RateLimitsResult, planType: String?, at date: Date) async throws {
        await acquire()
        defer { release() }
        try activity.check()
        let scope = result.accountId ?? planType ?? accountScope
        let changedAccount = accountScope != scope
        let previousCount = changedAccount ? nil : availableCount
        var statuses = changedAccount ? [:] : creditStatuses
        guard let summary = result.rateLimitResetCredits else { return }
        let perks = BarEvents.perkEvents(previous: loadState().perks, summary: summary, now: date)
        var events = perks.events
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
        if perks.observed != loadState().perks {
            var saved = loadState()
            saved.perks = perks.observed
            try save(saved)
        }
        // Missing detail rows are not evidence of redemption: the backend can
        // return a capped list or only the available count.
        accountScope = scope
        availableCount = summary.availableCount
        creditStatuses = statuses
    }

    private func loadState() -> TelemetryState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return TelemetryState() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let loaded = try decoder.decode(TelemetryState.self, from: Data(contentsOf: stateURL))
            state = loaded
            return loaded
        } catch {
            // Starting over costs one baseline; refusing to record would cost all of it.
            warnings.append("Tracking state was unreadable, so token counting restarted: \(error.localizedDescription)")
            state = TelemetryState()
            return TelemetryState()
        }
    }

    private func save(_ newState: TelemetryState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(newState)
        // Written under the activity lock: once stop() returns, no write can land after the
        // state file is discarded and bring old counts back.
        try activity.whileEnabled {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
        state = newState
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}

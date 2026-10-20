import Foundation

/// The Bar Telemetry Spec version this build writes as `bar.spec.version`.
public let barSpecVersion = "1"

/// One Limit as the Bar Telemetry Spec names it.
struct BarLimit: Sendable, Equatable {
    let id: String
    let name: String
    let windowMinutes: Int?
    let utilization: Double
    let resetsAt: TimeInterval?

    var attributes: [OTLPTelemetryEncoder.Attribute] {
        var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("limit.id", id), .init("limit.name", name)]
        if let windowMinutes { attributes.append(.init("limit.window.duration_minutes", windowMinutes)) }
        return attributes
    }

    static func limits(from result: RateLimitsResult) -> [BarLimit] {
        var seen = Set<String>()
        var limits: [BarLimit] = []
        for (bucketID, bucket) in result.orderedBuckets {
            for (role, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window, window.usedPercent.isFinite else { continue }
                // The window length keeps the ID stable when Codex swaps which window it
                // calls primary. Without a length the role is the only thing left to go on.
                let id = "\(bucketID):\(window.windowDurationMins.map(String.init) ?? role)"
                guard seen.insert(id).inserted else { continue }
                let windowName = UsageLimitMapper.windowName(for: window, role: role)
                let bucketName = bucket.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? bucketID
                let name = bucketID == "codex" ? windowName : "\(windowName) · \(UsageLimitMapper.humanize(bucketName))"
                limits.append(BarLimit(
                    id: id, name: name, windowMinutes: window.windowDurationMins,
                    utilization: min(max(window.usedPercent, 0), 100),
                    resetsAt: window.resetsAt.flatMap { $0.isFinite ? $0 : nil }
                ))
            }
        }
        return limits
    }
}

/// What the previous stamp saw, persisted so a change that happens while CodexBar is closed
/// still produces an event on the next stamp, and a relaunch doesn't repeat old ones.
struct ObservedLimit: Codable, Sendable, Equatable {
    var name: String
    var windowMinutes: Int?
    var utilization: Double
    var resetsAt: TimeInterval?
}

struct ObservedPerks: Codable, Sendable, Equatable {
    /// The account (or plan, when Codex gives no account ID) these perks belong to.
    var scope: String?
    var count: Int
    /// Available reset credits by ID, with their expiry when Codex reports one.
    var available: [String: TimeInterval?]
}

enum BarEvents {
    static func trackingStarted(intervalMinutes: Int) -> OTLPTelemetryEncoder.Event {
        .init(name: "bar.tracking.started", attributes: [.init("tracking.interval_minutes", intervalMinutes)])
    }

    static func observed(_ limits: [BarLimit]) -> [String: ObservedLimit] {
        Dictionary(limits.map {
            ($0.id, ObservedLimit(name: $0.name, windowMinutes: $0.windowMinutes, utilization: $0.utilization, resetsAt: $0.resetsAt))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Events for every Limit that appeared, reset, or disappeared since `previous`.
    /// `previous == nil` means nothing has been seen since tracking started, so every Limit appears.
    static func limitEvents(previous: [String: ObservedLimit]?, current: [BarLimit], now: Date) -> [OTLPTelemetryEncoder.Event] {
        let previous = previous ?? [:]
        var events: [OTLPTelemetryEncoder.Event] = []
        for limit in current {
            guard let before = previous[limit.id] else {
                events.append(.init(name: "bar.limit.appeared", attributes: limit.attributes))
                continue
            }
            if didReset(from: before, to: limit, now: now) {
                var attributes = limit.attributes + [.init("limit.utilization.last", before.utilization)]
                if let next = limit.resetsAt { attributes.append(.init("limit.resets_at.next", Int(next))) }
                events.append(.init(name: "bar.limit.reset", attributes: attributes))
            }
        }
        let currentIDs = Set(current.map(\.id))
        for (id, before) in previous.sorted(by: { $0.key < $1.key }) where !currentIDs.contains(id) {
            var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("limit.id", id), .init("limit.name", before.name)]
            if let minutes = before.windowMinutes { attributes.append(.init("limit.window.duration_minutes", minutes)) }
            events.append(.init(name: "bar.limit.disappeared", attributes: attributes))
        }
        return events
    }

    /// More than Codex's reset time drifts between reads, and more than a Window that hasn't
    /// started yet creeps forward per poll (its reset time is always a full Window from now).
    static let resetJumpTolerance: TimeInterval = 3_600

    /// A Window that runs to its end comes back ending roughly a whole Window later, so a
    /// jump of half a Window is a reset. Codex also resets a Window early, days before its
    /// end, and then the reset time only moves by what was left. Any jump past the drift
    /// tolerance counts as well when usage dropped or a full fresh Window now lies ahead.
    static func didReset(from before: ObservedLimit, to limit: BarLimit, now: Date) -> Bool {
        guard let old = before.resetsAt, let new = limit.resetsAt else {
            return usageDidReset(from: before.utilization, to: limit.utilization)
        }
        let jump = new - old
        if let minutes = limit.windowMinutes, jump >= Double(minutes) * 30 {
            return true
        }
        if limit.windowMinutes == nil, jump >= resetJumpTolerance {
            return true
        }
        guard jump > resetJumpTolerance else {
            return false
        }
        if usageDidReset(from: before.utilization, to: limit.utilization) {
            return true
        }
        // A Window not started yet also reads as a full Window ahead, and after a poll gap
        // its reset time can jump past the tolerance; usage going down is what tells a real
        // reset apart. An unused Window resetting can't be told apart, and loses nothing.
        guard let minutes = limit.windowMinutes, limit.utilization < before.utilization else {
            return false
        }
        let window = Double(minutes) * 60
        return abs(new - now.timeIntervalSince1970 - window) <= resetJumpTolerance
    }

    static func perkAttributes(id: String?, expiresAt: TimeInterval?, quantity: Int? = nil) -> [OTLPTelemetryEncoder.Attribute] {
        var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("perk.kind", "reset_credit")]
        if let id { attributes.append(.init("perk.id", id)) }
        if let expiresAt, expiresAt.isFinite { attributes.append(.init("perk.expires_at", Int(expiresAt))) }
        if let quantity { attributes.append(.init("perk.quantity", quantity)) }
        return attributes
    }

    /// Reset-credit events since `previous`, and the observation to keep.
    ///
    /// The available count is the truth for how many credits went: Codex can return a capped
    /// credit list, so a row missing from the list is only treated as gone when the count
    /// dropped too.
    static func perkEvents(
        previous: ObservedPerks?, summary: ResetCreditsSummary, now: Date
    ) -> (events: [OTLPTelemetryEncoder.Event], observed: ObservedPerks) {
        let previous = previous ?? ObservedPerks(scope: nil, count: 0, available: [:])
        let credits = summary.credits ?? []
        let statuses = Dictionary(credits.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        let availableNow = Dictionary(
            credits.filter { $0.status == "available" }.map { ($0.id, $0.expiresAt) }, uniquingKeysWith: { first, _ in first }
        )
        var events: [OTLPTelemetryEncoder.Event] = []
        var kept = previous.available

        let used = previous.available.keys.filter { ["redeemed", "redeeming"].contains(statuses[$0]) }.sorted()
        for id in used {
            events.append(.init(name: "bar.perk.gone", attributes: perkAttributes(id: id, expiresAt: previous.available[id] ?? nil)
                + [.init("perk.gone.reason", "used")]))
            kept[id] = nil
        }

        var goneBudget = previous.count - summary.availableCount - used.count
        let missing = kept.keys.filter { availableNow[$0] == nil }
            .sorted { (kept[$0].flatMap { $0 } ?? .infinity, $0) < (kept[$1].flatMap { $0 } ?? .infinity, $1) }
        for id in missing where goneBudget > 0 {
            let expiresAt = kept[id] ?? nil
            var attributes = perkAttributes(id: id, expiresAt: expiresAt)
            if let expiresAt, expiresAt <= now.timeIntervalSince1970 { attributes.append(.init("perk.gone.reason", "expired")) }
            events.append(.init(name: "bar.perk.gone", attributes: attributes))
            kept[id] = nil
            goneBudget -= 1
        }
        // Credits that went without a row to name them are one event for the whole count.
        if goneBudget > 0 {
            events.append(.init(name: "bar.perk.gone", attributes: perkAttributes(id: nil, expiresAt: nil, quantity: goneBudget)))
        }

        // Only a rise in the count is a new perk. A capped list can rotate which credits it
        // shows, so an ID seen for the first time without a rise is recorded silently.
        var appearBudget = summary.availableCount - previous.count + used.count
        for id in availableNow.keys.filter({ kept[$0] == nil }).sorted() {
            let expiresAt = availableNow[id] ?? nil
            if appearBudget > 0 {
                events.append(.init(name: "bar.perk.available", attributes: perkAttributes(id: id, expiresAt: expiresAt)))
                appearBudget -= 1
            }
            kept.updateValue(expiresAt, forKey: id)
        }
        if appearBudget > 0 {
            events.append(.init(name: "bar.perk.available", attributes: perkAttributes(id: nil, expiresAt: nil, quantity: appearBudget)))
        }
        // An expiry reported late, or moved, must be the one a later disappearance is judged by.
        for (id, expiresAt) in availableNow {
            if let expiresAt { kept.updateValue(expiresAt, forKey: id) }
        }
        return (events, ObservedPerks(scope: previous.scope, count: summary.availableCount, available: kept))
    }
}

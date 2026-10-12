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
    static func limitEvents(previous: [String: ObservedLimit]?, current: [BarLimit]) -> [OTLPTelemetryEncoder.Event] {
        let previous = previous ?? [:]
        var events: [OTLPTelemetryEncoder.Event] = []
        for limit in current {
            guard let before = previous[limit.id] else {
                events.append(.init(name: "bar.limit.appeared", attributes: limit.attributes))
                continue
            }
            if didReset(from: before, to: limit) {
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

    /// A rolled-over window ends roughly a whole window later than the old one did. Half a
    /// window is far beyond the few seconds Codex's reset time drifts between reads.
    static func didReset(from before: ObservedLimit, to limit: BarLimit) -> Bool {
        if let old = before.resetsAt, let new = limit.resetsAt {
            let threshold = limit.windowMinutes.map { Double($0) * 30 } ?? 3_600
            return new - old >= threshold
        }
        return usageDidReset(from: before.utilization, to: limit.utilization)
    }

    static func perkAttributes(id: String?, expiresAt: TimeInterval?) -> [OTLPTelemetryEncoder.Attribute] {
        var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("perk.kind", "reset_credit")]
        if let id { attributes.append(.init("perk.id", id)) }
        if let expiresAt, expiresAt.isFinite { attributes.append(.init("perk.expires_at", Int(expiresAt))) }
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
        let previous = previous ?? ObservedPerks(count: 0, available: [:])
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
        if goneBudget > 0 {
            events.append(.init(name: "bar.perk.gone", attributes: perkAttributes(id: nil, expiresAt: nil)))
        }

        let appeared = availableNow.keys.filter { kept[$0] == nil }.sorted()
        for id in appeared {
            let expiresAt = availableNow[id] ?? nil
            events.append(.init(name: "bar.perk.available", attributes: perkAttributes(id: id, expiresAt: expiresAt)))
            kept.updateValue(expiresAt, forKey: id)
        }
        if summary.availableCount - previous.count + used.count - appeared.count > 0 {
            events.append(.init(name: "bar.perk.available", attributes: perkAttributes(id: nil, expiresAt: nil)))
        }
        return (events, ObservedPerks(count: summary.availableCount, available: kept))
    }
}

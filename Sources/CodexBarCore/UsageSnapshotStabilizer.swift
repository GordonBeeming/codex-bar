import Foundation

public struct UsageSnapshotStabilizer: Sendable {
    public enum Decision: Sendable, Equatable {
        case accepted([UsageLimit])
        case held(confirmations: Int, required: Int)
    }

    private struct PendingRegression: Sendable {
        var limits: [UsageLimit]
        var confirmations: Int
    }

    private let requiredConsecutiveSamples: Int
    private let suspiciousDropPercent: Double
    private var trustedLimits: [UsageLimit]?
    private var pendingRegression: PendingRegression?

    public init(requiredConsecutiveSamples: Int = 3, suspiciousDropPercent: Double = 10) {
        self.requiredConsecutiveSamples = max(requiredConsecutiveSamples, 2)
        self.suspiciousDropPercent = max(suspiciousDropPercent, 1)
    }

    public mutating func evaluate(_ candidate: [UsageLimit]) -> Decision {
        guard let trustedLimits else {
            self.trustedLimits = candidate
            return .accepted(candidate)
        }

        guard isSuspiciousRegression(candidate, comparedWith: trustedLimits) else {
            self.trustedLimits = candidate
            pendingRegression = nil
            return .accepted(candidate)
        }

        if var pendingRegression, hasSameWindows(candidate, as: pendingRegression.limits) {
            pendingRegression.limits = candidate
            pendingRegression.confirmations += 1

            if pendingRegression.confirmations >= requiredConsecutiveSamples {
                self.trustedLimits = candidate
                self.pendingRegression = nil
                return .accepted(candidate)
            }

            self.pendingRegression = pendingRegression
            return .held(
                confirmations: pendingRegression.confirmations,
                required: requiredConsecutiveSamples
            )
        }

        pendingRegression = PendingRegression(limits: candidate, confirmations: 1)
        return .held(confirmations: 1, required: requiredConsecutiveSamples)
    }

    private func isSuspiciousRegression(
        _ candidate: [UsageLimit],
        comparedWith trusted: [UsageLimit]
    ) -> Bool {
        let trustedByID = Dictionary(uniqueKeysWithValues: trusted.map { ($0.id, $0) })

        return candidate.contains { current in
            guard let previous = trustedByID[current.id] else { return false }
            let drop = previous.percent - current.percent
            guard drop >= suspiciousDropPercent else { return false }
            return !hasConvincingResetAdvance(from: previous, to: current)
        }
    }

    private func hasConvincingResetAdvance(from previous: UsageLimit, to current: UsageLimit) -> Bool {
        guard
            let previousReset = previous.resetsAt,
            let currentReset = current.resetsAt,
            let durationMinutes = current.windowDurationMinutes,
            durationMinutes > 0
        else {
            return false
        }

        let windowDuration = TimeInterval(durationMinutes * 60)
        return currentReset.timeIntervalSince(previousReset) >= windowDuration * 0.5
    }

    private func hasSameWindows(_ lhs: [UsageLimit], as rhs: [UsageLimit]) -> Bool {
        let rhsByID = Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, $0) })
        guard Set(lhs.map(\.id)) == Set(rhsByID.keys) else { return false }

        return lhs.allSatisfy { current in
            guard let previous = rhsByID[current.id] else { return false }
            switch (current.resetsAt, previous.resetsAt) {
            case let (currentReset?, previousReset?):
                return abs(currentReset.timeIntervalSince(previousReset)) <= 300
            case (nil, nil):
                return true
            default:
                return false
            }
        }
    }
}

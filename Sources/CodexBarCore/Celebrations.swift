import Foundation

public enum ReactionChoice: String, CaseIterable, Sendable {
    case confetti
    case balloons
    case fireworks
    case rain
    case lasers
    case hearts
    case thumbsUp
    case thumbsDown

    public var displayName: String {
        switch self {
        case .confetti: return "Confetti"
        case .balloons: return "Balloons"
        case .fireworks: return "Fireworks"
        case .rain: return "Rain"
        case .lasers: return "Lasers"
        case .hearts: return "Hearts"
        case .thumbsUp: return "Thumbs up"
        case .thumbsDown: return "Thumbs down"
        }
    }
}

public enum CelebrationTrigger: String, CaseIterable, Sendable {
    case sessionReset
    case weeklyReset
    case overWeeklyPace

    public var displayName: String {
        switch self {
        case .sessionReset: return "Session (5h) reset"
        case .weeklyReset: return "Weekly reset"
        case .overWeeklyPace: return "Burning over weekly pace"
        }
    }

    public var defaultReaction: ReactionChoice {
        switch self {
        case .sessionReset: return .confetti
        case .weeklyReset: return .fireworks
        case .overWeeklyPace: return .rain
        }
    }
}

public struct LimitSnapshot: Sendable {
    private static let rearmBufferPercent = 1.0

    public let percent: Double
    public let overPaceLatched: Bool

    public init(percent: Double, overPaceLatched: Bool) {
        self.percent = percent
        self.overPaceLatched = overPaceLatched
    }

    public static func next(after previous: Self?, for limit: UsageLimit, now: Date) -> Self {
        let didReset = previous.map {
            $0.percent - limit.percent > resetDropThreshold && limit.percent < resetFloor
        } ?? false
        let isOverPace = UsageWindow.isAheadOfPace(for: limit, now: now)
        let isClearlyUnderPace = !UsageWindow.isAheadOfPace(
            for: limit,
            now: now,
            marginPercent: -rearmBufferPercent
        )
        return Self(
            percent: limit.percent,
            overPaceLatched: isOverPace
                || (!didReset && !isClearlyUnderPace && previous?.overPaceLatched == true)
        )
    }
}

public let resetDropThreshold = 25.0
public let resetFloor = 10.0

public func detectCelebrationEvents(
    previous: [String: LimitSnapshot],
    current: [UsageLimit],
    now: Date
) -> Set<CelebrationTrigger> {
    var fired: Set<CelebrationTrigger> = []

    for limit in current {
        guard let prior = previous[limit.celebrationKey] else { continue }

        let didReset = prior.percent - limit.percent > resetDropThreshold && limit.percent < resetFloor
        if didReset {
            switch limit.group {
            case "session": fired.insert(.sessionReset)
            case "weekly": fired.insert(.weeklyReset)
            default: break
            }
        }

        if limit.group == "weekly" {
            let isOverPace = UsageWindow.isAheadOfPace(for: limit, now: now)
            if isOverPace, didReset || !prior.overPaceLatched {
                fired.insert(.overWeeklyPace)
            }
        }
    }

    return fired
}

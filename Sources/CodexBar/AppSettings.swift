import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let useDefaultSeverity = "useDefaultSeverity"
        static let warningThresholdPercent = "warningThresholdPercent"
        static let criticalThresholdPercent = "criticalThresholdPercent"
        static let showMenuBarFlame = "showMenuBarFlame"
        static let celebrationsEnabled = "celebrationsEnabled"

        static func celebrationEnabled(_ trigger: CelebrationTrigger) -> String {
            "celebration.\(trigger.rawValue).enabled"
        }

        static func celebrationReaction(_ trigger: CelebrationTrigger) -> String {
            "celebration.\(trigger.rawValue).reaction"
        }
    }

    private let defaults = UserDefaults.standard

    var useDefaultSeverity: Bool {
        didSet { defaults.set(useDefaultSeverity, forKey: Keys.useDefaultSeverity) }
    }

    var showMenuBarFlame: Bool {
        didSet { defaults.set(showMenuBarFlame, forKey: Keys.showMenuBarFlame) }
    }

    var celebrationsEnabled: Bool {
        didSet { defaults.set(celebrationsEnabled, forKey: Keys.celebrationsEnabled) }
    }

    private var celebrationEnabledStore: [String: Bool]
    private var celebrationReactionStore: [String: ReactionChoice]

    func celebrationEnabled(for trigger: CelebrationTrigger) -> Bool {
        celebrationEnabledStore[trigger.rawValue] ?? true
    }

    func setCelebrationEnabled(_ enabled: Bool, for trigger: CelebrationTrigger) {
        celebrationEnabledStore[trigger.rawValue] = enabled
        defaults.set(enabled, forKey: Keys.celebrationEnabled(trigger))
    }

    func reaction(for trigger: CelebrationTrigger) -> ReactionChoice {
        celebrationReactionStore[trigger.rawValue] ?? trigger.defaultReaction
    }

    func setReaction(_ reaction: ReactionChoice, for trigger: CelebrationTrigger) {
        celebrationReactionStore[trigger.rawValue] = reaction
        defaults.set(reaction.rawValue, forKey: Keys.celebrationReaction(trigger))
    }

    private var storedWarningThresholdPercent: Double
    var warningThresholdPercent: Double {
        get { storedWarningThresholdPercent }
        set {
            storedWarningThresholdPercent = Self.clamp(newValue)
            defaults.set(storedWarningThresholdPercent, forKey: Keys.warningThresholdPercent)
        }
    }

    private var storedCriticalThresholdPercent: Double
    var criticalThresholdPercent: Double {
        get { storedCriticalThresholdPercent }
        set {
            storedCriticalThresholdPercent = Self.clamp(newValue)
            defaults.set(storedCriticalThresholdPercent, forKey: Keys.criticalThresholdPercent)
        }
    }

    var thresholds: SeverityThresholds {
        SeverityThresholds(
            useDefaults: useDefaultSeverity,
            warningPercent: warningThresholdPercent,
            criticalPercent: criticalThresholdPercent
        )
    }

    init() {
        var registrations: [String: Any] = [
            Keys.useDefaultSeverity: true,
            Keys.warningThresholdPercent: 75.0,
            Keys.criticalThresholdPercent: 90.0,
            Keys.showMenuBarFlame: true,
            Keys.celebrationsEnabled: false
        ]
        for trigger in CelebrationTrigger.allCases {
            registrations[Keys.celebrationEnabled(trigger)] = true
            registrations[Keys.celebrationReaction(trigger)] = trigger.defaultReaction.rawValue
        }
        defaults.register(defaults: registrations)

        useDefaultSeverity = defaults.bool(forKey: Keys.useDefaultSeverity)
        showMenuBarFlame = defaults.bool(forKey: Keys.showMenuBarFlame)
        celebrationsEnabled = defaults.bool(forKey: Keys.celebrationsEnabled)

        var enabledStore: [String: Bool] = [:]
        var reactionStore: [String: ReactionChoice] = [:]
        for trigger in CelebrationTrigger.allCases {
            enabledStore[trigger.rawValue] = defaults.bool(forKey: Keys.celebrationEnabled(trigger))
            let rawReaction = defaults.string(forKey: Keys.celebrationReaction(trigger))
            reactionStore[trigger.rawValue] = rawReaction.flatMap(ReactionChoice.init(rawValue:))
                ?? trigger.defaultReaction
        }
        celebrationEnabledStore = enabledStore
        celebrationReactionStore = reactionStore
        storedWarningThresholdPercent = Self.clamp(defaults.double(forKey: Keys.warningThresholdPercent))
        storedCriticalThresholdPercent = Self.clamp(defaults.double(forKey: Keys.criticalThresholdPercent))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 1), 100)
    }
}

import CodexBarCore
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class UsageViewModel {
    private(set) var limits: [UsageLimit] = []
    private(set) var planType: String?
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    private let client = CodexAppServerClient()
    private let logger = Logger(subsystem: "com.gordonbeeming.CodexBar", category: "Usage")
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var previousSnapshots: [String: LimitSnapshot] = [:]
    @ObservationIgnored private var hasSeededCelebrations = false
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var celebrations: CelebrationController?
    @ObservationIgnored private var snapshotStabilizer = UsageSnapshotStabilizer()

    private static let staleThreshold: TimeInterval = 30
    private static let didApplyDefaultLaunchAtLoginKey = "didApplyDefaultLaunchAtLogin"

    var highest: UsageLimit? {
        limits.max { $0.percent < $1.percent }
    }

    var launchAtLoginAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var launchAtLogin = LaunchAtLoginManager.isEnabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LaunchAtLoginManager.setEnabled(launchAtLogin)
            } catch {
                logger.error("launch-at-login update failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Couldn't update launch at login"
                launchAtLogin = oldValue
            }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        applyDefaultLaunchAtLoginIfNeeded()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await client.fetchUsage()
            planType = snapshot.planType
            lastUpdated = Date()
            lastError = nil

            switch snapshotStabilizer.evaluate(snapshot.limits, planType: snapshot.planType) {
            case let .accepted(trustedLimits):
                limits = trustedLimits
                processCelebrations(for: trustedLimits, now: Date())
            case let .acceptedPlanChange(trustedLimits):
                limits = trustedLimits
                hasSeededCelebrations = false
                processCelebrations(for: trustedLimits, now: Date())
                logger.notice("accepted usage immediately because the Codex plan changed")
            case let .held(confirmations, required):
                logger.notice(
                    "held suspicious usage regression pending confirmation (\(confirmations, privacy: .public)/\(required, privacy: .public))"
                )
            }
        } catch {
            logger.error("usage refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func refreshIfStale() {
        let isStale = lastUpdated.map { Date().timeIntervalSince($0) > Self.staleThreshold } ?? true
        guard isStale else { return }
        Task { await refresh() }
    }

    func attachCelebrations(settings: AppSettings, controller: CelebrationController) {
        self.settings = settings
        celebrations = controller
    }

    func previewCelebration(_ choice: ReactionChoice) {
        celebrations?.play(choice)
    }

    private func processCelebrations(for limits: [UsageLimit], now: Date) {
        let snapshots = Dictionary(
            limits.map { limit in
                (
                    limit.celebrationKey,
                    LimitSnapshot(
                        percent: limit.percent,
                        overPace: UsageWindow.isAheadOfPace(for: limit, now: now)
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        defer { previousSnapshots = snapshots }

        guard hasSeededCelebrations else {
            hasSeededCelebrations = true
            return
        }
        guard let settings, settings.celebrationsEnabled else { return }

        let events = detectCelebrationEvents(previous: previousSnapshots, current: limits, now: now)
        let reactions = Set(
            events
                .filter { settings.celebrationEnabled(for: $0) }
                .map { settings.reaction(for: $0) }
        )
        for reaction in reactions {
            celebrations?.play(reaction)
        }
    }

    private func applyDefaultLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didApplyDefaultLaunchAtLoginKey), launchAtLoginAvailable else {
            return
        }
        do {
            try LaunchAtLoginManager.setEnabled(true)
            launchAtLogin = true
            defaults.set(true, forKey: Self.didApplyDefaultLaunchAtLoginKey)
        } catch {
            logger.error("default launch-at-login registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}

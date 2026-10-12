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
    private(set) var telemetryError: String?
    private(set) var lastTelemetryWrite: Date?

    private let client: any UsageFetching
    private let pollInterval: Duration
    private let captureInterval: @Sendable (Int) -> Duration
    private let configuredCodexHome: URL?
    private let telemetryStateURL: URL
    /// Set when turning tracking off couldn't delete the state. Tracking stays off until the
    /// delete succeeds, so tokens used while it was off are never counted.
    @ObservationIgnored private var stateResetPending = false
    private let logger = Logger(subsystem: "com.gordonbeeming.CodexBar", category: "Usage")
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var telemetryTask: Task<Void, Never>?
    @ObservationIgnored private var telemetryRecorder: TelemetryRecorder?
    @ObservationIgnored private var telemetryConfiguration: TelemetryConfiguration?
    @ObservationIgnored private var telemetryGeneration = UUID()
    @ObservationIgnored private var latestSnapshot: UsageSnapshot?
    @ObservationIgnored private var snapshotObservedAt: Date?
    @ObservationIgnored private var telemetrySinks: [URL: LocalTelemetrySink] = [:]
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var settingsObservationGeneration = UUID()
    @ObservationIgnored private var previousSnapshots: [String: LimitSnapshot] = [:]
    @ObservationIgnored private var hasSeededCelebrations = false
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var celebrations: CelebrationController?
    @ObservationIgnored private var snapshotStabilizer = UsageSnapshotStabilizer()

    private static let staleThreshold: TimeInterval = 30
    private static let didApplyDefaultLaunchAtLoginKey = "didApplyDefaultLaunchAtLogin"

    init(
        client: any UsageFetching = CodexAppServerClient(), pollInterval: Duration = .seconds(60),
        captureInterval: @escaping @Sendable (Int) -> Duration = { .seconds($0 * 60) }, codexHome: URL? = nil,
        telemetryStateURL: URL = TelemetryRecorder.defaultStateURL
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.captureInterval = captureInterval
        self.configuredCodexHome = codexHome
        self.telemetryStateURL = telemetryStateURL
    }

    func stop() {
        settingsObservationGeneration = UUID()
        telemetryGeneration = UUID()
        pollTask?.cancel()
        pollTask = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        telemetryRecorder?.stop()
        telemetryRecorder = nil
        telemetryConfiguration = nil
    }

    func start(settings: AppSettings, celebrations: CelebrationController) {
        attachCelebrations(settings: settings, controller: celebrations)
        settingsObservationGeneration = UUID()
        observeTelemetrySettings(settings, generation: settingsObservationGeneration)
        startPolling()
    }

    private func observeTelemetrySettings(_ settings: AppSettings, generation: UUID) {
        guard generation == settingsObservationGeneration else { return }
        let configuration = withObservationTracking {
            settings.telemetryConfiguration
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.observeTelemetrySettings(settings, generation: generation)
            }
        }
        configureTelemetry(configuration)
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
                do { try await Task.sleep(for: self.pollInterval) }
                catch { return }
            }
        }
    }

    func refresh() async {
        if isRefreshing {
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        do {
            let snapshot = try await client.fetchUsage(includeTokenUsage: telemetryRecorder != nil)
            latestSnapshot = snapshot
            snapshotObservedAt = Date()
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
            if let recorder = telemetryRecorder {
                let generation = telemetryGeneration
                do {
                    try await recorder.observeResetCredits(result: snapshot.rateLimits,
                                                           planType: snapshot.planType, at: Date())
                } catch {
                    reportTelemetryFailure(error, generation: generation)
                }
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

    func configureTelemetry(_ configuration: TelemetryConfiguration) {
        guard configuration != telemetryConfiguration else { return }
        let previousConfiguration = telemetryConfiguration
        let previousRecorder = telemetryRecorder
        telemetryConfiguration = configuration
        telemetryTask?.cancel()
        telemetryTask = nil
        telemetryGeneration = UUID()
        telemetryError = nil
        guard configuration.enabled else {
            telemetryRecorder = nil
            lastTelemetryWrite = nil
            previousRecorder?.stop()
            // Tokens used while tracking is off must never be counted, so turning it back on
            // starts a new count with a new start time.
            stateResetPending = true
            resetTrackingStateIfPending()
            return
        }
        guard resetTrackingStateIfPending() else {
            // Forget this configuration so the next settings change retries the reset.
            telemetryConfiguration = nil
            return
        }
        let reuseRecorder = previousConfiguration?.enabled == true && previousConfiguration?.directory == configuration.directory
        // Stopped before a replacement exists so the old one can't write state after it.
        if !reuseRecorder { previousRecorder?.stop() }
        let recorder: TelemetryRecorder
        if reuseRecorder, let previousRecorder { recorder = previousRecorder }
        else {
            let directory = configuration.directory.standardizedFileURL
            let sink = telemetrySinks[directory] ?? LocalTelemetrySink(directory: directory)
            telemetrySinks[directory] = sink
            let environment = ProcessInfo.processInfo.environment
            let codexHome = configuredCodexHome
                ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
            recorder = TelemetryRecorder(
                sink: sink, retentionDays: configuration.retentionDays,
                serviceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                intervalMinutes: configuration.intervalMinutes, stateURL: telemetryStateURL,
                scanner: SessionTokenScanner(codexHome: codexHome)
            )
            lastTelemetryWrite = nil
        }
        telemetryRecorder = recorder
        recorder.updateRetentionDays(configuration.retentionDays)
        let generation = telemetryGeneration
        let interval = captureInterval(configuration.intervalMinutes)
        telemetryTask = Task { [weak self] in
            guard !Task.isCancelled, self?.telemetryGeneration == generation else { return }
            let clock = ContinuousClock()
            var nextCapture = clock.now
            if reuseRecorder {
                nextCapture = nextCapture.advanced(by: interval)
                do { try await clock.sleep(until: nextCapture) }
                catch { return }
            }
            while !Task.isCancelled {
                guard let self, self.telemetryGeneration == generation else { return }
                await self.captureTelemetry(recorder: recorder, generation: generation)
                nextCapture = nextCapture.advanced(by: interval)
                if nextCapture < clock.now { nextCapture = clock.now.advanced(by: interval) }
                do {
                    try await clock.sleep(until: nextCapture)
                } catch { return }
            }
        }
    }

    @discardableResult
    private func resetTrackingStateIfPending() -> Bool {
        guard stateResetPending else { return true }
        do {
            try TelemetryRecorder.discardState(at: telemetryStateURL)
            stateResetPending = false
            return true
        } catch {
            telemetryError = "Couldn't reset tracking state, so recording stays paused: \(error.localizedDescription)"
            logger.error("telemetry state reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func captureTelemetry(recorder: TelemetryRecorder, generation: UUID) async {
        if needsTelemetryRefresh {
            await refresh()
        }
        guard !Task.isCancelled, generation == telemetryGeneration else { return }
        // Select account data at capture time so an expired cached response is never exported.
        let isFresh = snapshotObservedAt.map { Date().timeIntervalSince($0) <= 120 } ?? false
        let snapshot = isFresh ? latestSnapshot : nil
        let observedAt = snapshot == nil ? nil : snapshotObservedAt
        do {
            let capturedAt = Date()
            if let snapshot {
                try await recorder.observeResetCredits(result: snapshot.rateLimits,
                                                       planType: snapshot.planType, at: capturedAt)
            }
            guard !Task.isCancelled, generation == telemetryGeneration else { return }
            try await recorder.recordSample(result: snapshot?.rateLimits, planType: snapshot?.planType,
                                            observedAt: observedAt,
                                            at: capturedAt, accountTokens: snapshot?.tokenUsage)
            guard generation == telemetryGeneration else { return }
            lastTelemetryWrite = capturedAt
            var warnings = await recorder.exportWarnings()
            guard generation == telemetryGeneration else { return }
            if let error = snapshot?.tokenUsageError { warnings.append("Account token summary unavailable: \(error)") }
            if snapshot == nil { warnings.append("Codex usage unavailable; recorded local tokens only") }
            telemetryError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            reportTelemetryFailure(error, generation: generation)
        }
    }

    private var needsTelemetryRefresh: Bool {
        (snapshotObservedAt.map { Date().timeIntervalSince($0) > Self.staleThreshold } ?? true)
            || (latestSnapshot?.tokenUsage == nil && latestSnapshot?.tokenUsageError == nil)
    }

    private func reportTelemetryFailure(_ error: Error, generation: UUID) {
        guard generation == telemetryGeneration else { return }
        telemetryError = error.localizedDescription
        logger.error("telemetry export failed: \(error.localizedDescription, privacy: .public)")
    }

    func previewCelebration(_ choice: ReactionChoice) {
        celebrations?.play(choice)
    }

    private func processCelebrations(for limits: [UsageLimit], now: Date) {
        let snapshots = Dictionary(
            limits.map { limit in
                (
                    limit.celebrationKey,
                    LimitSnapshot.next(
                        after: hasSeededCelebrations ? previousSnapshots[limit.celebrationKey] : nil,
                        for: limit,
                        now: now
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

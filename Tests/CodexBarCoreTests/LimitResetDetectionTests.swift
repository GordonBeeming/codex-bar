import Foundation
import XCTest
@testable import CodexBarCore

/// Window rollovers taken from real CodexBar telemetry: Codex reset the Weekly Window early,
/// days before its reset time, so the reset time jumped about two days, not a whole Window.
final class LimitResetDetectionTests: XCTestCase {
    private func observed(_ utilization: Double, resetsAt: TimeInterval?) -> ObservedLimit {
        ObservedLimit(name: "Weekly", windowMinutes: 10_080, utilization: utilization, resetsAt: resetsAt)
    }

    private func limit(_ utilization: Double, resetsAt: TimeInterval?) -> BarLimit {
        BarLimit(id: "codex:10080", name: "Weekly", windowMinutes: 10_080, utilization: utilization, resetsAt: resetsAt)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testEarlyWeeklyResetsFromRealTelemetryCount() {
        // (sample time, old reset time, old usage, new reset time, new usage) for 13, 15 and 18 Oct.
        let rollovers: [(TimeInterval, TimeInterval, Double, TimeInterval, Double)] = [
            (1_791_867_609, 1_792_310_768, 6, 1_792_472_409, 0),
            (1_792_044_791, 1_792_475_653, 5, 1_792_649_591, 0),
            (1_792_269_763, 1_792_652_811, 6, 1_792_874_563, 0)
        ]
        for (time, oldReset, oldUsage, newReset, newUsage) in rollovers {
            XCTAssertTrue(
                BarEvents.didReset(from: observed(oldUsage, resetsAt: oldReset), to: limit(newUsage, resetsAt: newReset), now: at(time)),
                "rollover at \(time)"
            )
        }
    }

    func testAnEarlyResetWithUsageAlreadyBackCountsWhenAFullWindowStarts() {
        // Usage went from 6% to 1% (a request landed straight after the reset), too small a
        // drop for the usage check on its own, but a full fresh Window lies ahead.
        // The old Window had five days left, so the two-day jump stays under half a Window
        // and only the full-Window check can catch it.
        let now: TimeInterval = 1_792_000_000
        XCTAssertTrue(BarEvents.didReset(
            from: observed(6, resetsAt: now + 5 * 86_400),
            to: limit(1, resetsAt: now + 7 * 86_400),
            now: at(now)
        ))
    }

    func testASmallUsageDipWithoutAFullWindowAheadIsNotAReset() {
        // The same two-day jump and 6% to 1% dip, but the new reset time is only three days
        // out, so no fresh Window started.
        let now: TimeInterval = 1_792_000_000
        XCTAssertFalse(BarEvents.didReset(
            from: observed(6, resetsAt: now + 1 * 86_400),
            to: limit(1, resetsAt: now + 3 * 86_400),
            now: at(now)
        ))
    }

    func testAWindowNotStartedYetSeenAcrossAPollGapIsNotAReset() {
        // Two hours asleep: the not-yet-started Window's reset time moved two hours, past the
        // tolerance, and still reads as a full Window ahead, but usage stayed at zero.
        let now: TimeInterval = 1_792_000_000
        XCTAssertFalse(BarEvents.didReset(
            from: observed(0, resetsAt: now - 7_200 + 604_800),
            to: limit(0, resetsAt: now + 604_800),
            now: at(now)
        ))
    }

    func testAFewMinutesOfDriftIsNotAReset() {
        let now: TimeInterval = 1_792_000_000
        XCTAssertFalse(BarEvents.didReset(from: observed(6, resetsAt: now + 86_400), to: limit(6, resetsAt: now + 86_400 + 300), now: at(now)))
    }

    func testAWindowThatHasNotStartedIsNotAResetEachPoll() {
        // Before the first request in a Window, Codex reports the reset a full Window from now,
        // so it creeps forward with every poll while usage stays at zero.
        let now: TimeInterval = 1_792_000_000
        XCTAssertFalse(BarEvents.didReset(
            from: observed(0, resetsAt: now - 600 + 604_800),
            to: limit(0, resetsAt: now + 604_800),
            now: at(now)
        ))
    }

    func testAUsageDropWithoutTheResetTimeMovingIsNotAReset() {
        let now: TimeInterval = 1_792_000_000
        XCTAssertFalse(BarEvents.didReset(from: observed(40, resetsAt: now + 86_400), to: limit(0, resetsAt: now + 86_400), now: at(now)))
    }

    func testAWindowRunningToItsEndStillCounts() {
        let now: TimeInterval = 1_800_000_000
        XCTAssertTrue(BarEvents.didReset(from: observed(81, resetsAt: 1_800_000_004), to: limit(2, resetsAt: 1_800_604_800), now: at(now)))
    }
}

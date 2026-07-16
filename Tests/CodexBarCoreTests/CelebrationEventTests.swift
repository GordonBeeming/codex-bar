import Foundation
import XCTest
@testable import CodexBarCore

final class CelebrationEventTests: XCTestCase {
    func testSessionResetFiresOnLargeDrop() {
        let current = limit(id: "codex.primary", percent: 4, duration: 300)
        let previous = [current.id: LimitSnapshot(percent: 80, overPaceLatched: true)]

        XCTAssertEqual(
            detectCelebrationEvents(previous: previous, current: [current], now: .now),
            [.sessionReset]
        )
    }

    func testSessionResetFiresWhenUsageReturnsToZero() {
        let current = limit(id: "codex.primary", percent: 0, duration: 300)
        let previous = [current.id: LimitSnapshot(percent: 20, overPaceLatched: true)]

        XCTAssertEqual(
            detectCelebrationEvents(previous: previous, current: [current], now: .now),
            [.sessionReset]
        )
    }

    func testSessionResetDoesNotFireOnSmallNonzeroDrop() {
        let current = limit(id: "codex.primary", percent: 4, duration: 300)
        let previous = [current.id: LimitSnapshot(percent: 20, overPaceLatched: true)]

        XCTAssertEqual(
            detectCelebrationEvents(previous: previous, current: [current], now: .now),
            []
        )
    }

    func testWeeklyResetFiresOnLargeDrop() {
        let current = limit(id: "codex.secondary", percent: 2, duration: 10_080)
        let previous = [current.id: LimitSnapshot(percent: 55, overPaceLatched: true)]

        XCTAssertTrue(
            detectCelebrationEvents(previous: previous, current: [current], now: .now)
                .contains(.weeklyReset)
        )
    }

    func testWeeklyResetFiresWhenUsageReturnsToZero() {
        let current = limit(id: "codex.secondary", percent: 0, duration: 10_080)
        let previous = [current.id: LimitSnapshot(percent: 20, overPaceLatched: true)]

        XCTAssertTrue(
            detectCelebrationEvents(previous: previous, current: [current], now: .now)
                .contains(.weeklyReset)
        )
    }

    func testUsageReturningToZeroClearsOverPaceLatch() {
        let current = limit(id: "codex.secondary", percent: 0, duration: 10_080)
        let previous = LimitSnapshot(percent: 20, overPaceLatched: true)

        XCTAssertFalse(
            LimitSnapshot.next(after: previous, for: current, now: .now).overPaceLatched
        )
    }

    func testWeeklyResetCanAlsoFireOverPace() {
        let now = Date(timeIntervalSince1970: 5_000)
        let current = UsageLimit(
            id: "codex.secondary",
            name: "Weekly",
            percent: 9,
            resetsAt: now.addingTimeInterval(10_080 * 60),
            windowDurationMinutes: 10_080
        )
        let previous = [current.id: LimitSnapshot(percent: 80, overPaceLatched: true)]

        XCTAssertEqual(
            detectCelebrationEvents(previous: previous, current: [current], now: now),
            [.weeklyReset, .overWeeklyPace]
        )
    }

    func testWeeklyOverPaceFiresOnlyOnRisingEdge() {
        let now = Date(timeIntervalSince1970: 5_000)
        let current = UsageLimit(
            id: "codex.secondary",
            name: "Weekly",
            percent: 60,
            resetsAt: now.addingTimeInterval(TimeInterval(10_080 * 30)),
            windowDurationMinutes: 10_080
        )

        let below = [current.id: LimitSnapshot(percent: 50, overPaceLatched: false)]
        let alreadyOver = [current.id: LimitSnapshot(percent: 50, overPaceLatched: true)]

        XCTAssertTrue(
            detectCelebrationEvents(previous: below, current: [current], now: now)
                .contains(.overWeeklyPace)
        )
        XCTAssertFalse(
            detectCelebrationEvents(previous: alreadyOver, current: [current], now: now)
                .contains(.overWeeklyPace)
        )
    }

    func testWeeklyOverPaceRearmsOnlyAfterClearlyUnderPace() {
        let now = Date(timeIntervalSince1970: 5_000)
        let duration = TimeInterval(10_080 * 60)
        let current = UsageLimit(
            id: "codex.secondary",
            name: "Weekly",
            percent: 60,
            resetsAt: now.addingTimeInterval(duration / 2),
            windowDurationMinutes: 10_080
        )

        let first = LimitSnapshot.next(after: nil, for: current, now: now)
        let nearBoundaryTime = now.addingTimeInterval(duration * 0.105) // 0.5 points under pace.
        let nearBoundary = LimitSnapshot.next(
            after: first,
            for: current,
            now: nearBoundaryTime
        )
        let clearlyUnderTime = now.addingTimeInterval(duration * 0.12) // 2 points under pace.
        let clearlyUnder = LimitSnapshot.next(
            after: nearBoundary,
            for: current,
            now: clearlyUnderTime
        )
        let reentered = UsageLimit(
            id: current.id,
            name: current.name,
            percent: 63,
            resetsAt: current.resetsAt,
            windowDurationMinutes: current.windowDurationMinutes
        )

        XCTAssertTrue(first.overPaceLatched)
        XCTAssertTrue(nearBoundary.overPaceLatched)
        XCTAssertFalse(clearlyUnder.overPaceLatched)
        XCTAssertTrue(
            detectCelebrationEvents(
                previous: [current.id: clearlyUnder],
                current: [reentered],
                now: clearlyUnderTime
            ).contains(.overWeeklyPace)
        )
    }

    private func limit(id: String, percent: Double, duration: Int) -> UsageLimit {
        UsageLimit(
            id: id,
            name: duration == 300 ? "Session (5h)" : "Weekly",
            percent: percent,
            resetsAt: Date().addingTimeInterval(TimeInterval(duration * 60)),
            windowDurationMinutes: duration
        )
    }
}

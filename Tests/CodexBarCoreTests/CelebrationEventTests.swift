import Foundation
import XCTest
@testable import CodexBarCore

final class CelebrationEventTests: XCTestCase {
    func testSessionResetFiresOnLargeDrop() {
        let current = limit(id: "codex.primary", percent: 4, duration: 300)
        let previous = [current.id: LimitSnapshot(percent: 80, overPace: true)]

        XCTAssertEqual(
            detectCelebrationEvents(previous: previous, current: [current], now: .now),
            [.sessionReset]
        )
    }

    func testWeeklyResetFiresOnLargeDrop() {
        let current = limit(id: "codex.secondary", percent: 2, duration: 10_080)
        let previous = [current.id: LimitSnapshot(percent: 55, overPace: true)]

        XCTAssertTrue(
            detectCelebrationEvents(previous: previous, current: [current], now: .now)
                .contains(.weeklyReset)
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

        let below = [current.id: LimitSnapshot(percent: 50, overPace: false)]
        let alreadyOver = [current.id: LimitSnapshot(percent: 50, overPace: true)]

        XCTAssertTrue(
            detectCelebrationEvents(previous: below, current: [current], now: now)
                .contains(.overWeeklyPace)
        )
        XCTAssertFalse(
            detectCelebrationEvents(previous: alreadyOver, current: [current], now: now)
                .contains(.overWeeklyPace)
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

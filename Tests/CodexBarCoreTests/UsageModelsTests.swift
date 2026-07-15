import Foundation
import XCTest
@testable import CodexBarCore

final class UsageModelsTests: XCTestCase {
    func testMapsPrimaryAndSecondaryWindows() {
        let bucket = RateLimitBucket(
            limitId: "codex",
            limitName: nil,
            planType: "plus",
            primary: RateLimitWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: 1_783_653_303),
            secondary: RateLimitWindow(usedPercent: 4, windowDurationMins: 10_080, resetsAt: 1_784_240_103)
        )
        let result = RateLimitsResult(rateLimits: bucket, rateLimitsByLimitId: nil)

        let limits = UsageLimitMapper.limits(from: result)

        XCTAssertEqual(limits.map(\.name), ["Session (5h)", "Weekly"])
        XCTAssertEqual(limits.map(\.percent), [25, 4])
        XCTAssertEqual(limits.map(\.windowDurationMinutes), [300, 10_080])
        XCTAssertEqual(UsageLimitMapper.planType(from: result, account: nil), "plus")
    }

    func testUsesMultiBucketViewWhenPresent() {
        let legacy = RateLimitBucket(
            limitId: "legacy",
            limitName: nil,
            planType: nil,
            primary: RateLimitWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: nil),
            secondary: nil
        )
        let codex = RateLimitBucket(
            limitId: "codex",
            limitName: "Codex",
            planType: "pro",
            primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
            secondary: nil
        )
        let other = RateLimitBucket(
            limitId: "codex_other",
            limitName: "Review",
            planType: "pro",
            primary: RateLimitWindow(usedPercent: 20, windowDurationMins: 60, resetsAt: nil),
            secondary: nil
        )
        let result = RateLimitsResult(
            rateLimits: legacy,
            rateLimitsByLimitId: ["codex_other": other, "codex": codex]
        )

        let limits = UsageLimitMapper.limits(from: result)

        XCTAssertEqual(limits.map(\.id), ["codex.primary", "codex_other.primary"])
        XCTAssertEqual(limits.map(\.name), ["Session (5h) — Codex", "1-hour window — Review"])
    }

    func testPaceUsesWindowStartAndReset() {
        let now = Date(timeIntervalSince1970: 1_800)
        let limit = UsageLimit(
            id: "codex.primary",
            name: "Session (5h)",
            percent: 60,
            resetsAt: Date(timeIntervalSince1970: 3_600),
            windowDurationMinutes: 60
        )

        XCTAssertEqual(UsageWindow.paceFraction(for: limit, now: now), 0.5)
        XCTAssertTrue(UsageWindow.isAheadOfPace(for: limit, now: now))
    }

    func testAheadOfPaceStartsAboveFivePercent() {
        let now = Date(timeIntervalSince1970: 0)
        let resetsAt = now.addingTimeInterval(300 * 60)

        XCTAssertFalse(UsageWindow.isAheadOfPace(for: limit(percent: 5, resetsAt: resetsAt), now: now))
        XCTAssertTrue(UsageWindow.isAheadOfPace(for: limit(percent: 5.1, resetsAt: resetsAt), now: now))
    }

    func testClampsServerPercent() {
        let bucket = RateLimitBucket(
            limitId: "codex",
            limitName: nil,
            planType: nil,
            primary: RateLimitWindow(usedPercent: 120, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindow(usedPercent: -5, windowDurationMins: 10_080, resetsAt: nil)
        )

        let limits = UsageLimitMapper.limits(
            from: RateLimitsResult(rateLimits: bucket, rateLimitsByLimitId: nil)
        )

        XCTAssertEqual(limits.map(\.percent), [100, 0])
    }

    func testDefaultSeverityUsesDefaultThresholds() {
        XCTAssertEqual(limit(percent: 74).defaultSeverity, .normal)
        XCTAssertEqual(limit(percent: 75).defaultSeverity, .warning)
        XCTAssertEqual(limit(percent: 90).defaultSeverity, .critical)
    }

    private func limit(percent: Double, resetsAt: Date? = nil) -> UsageLimit {
        UsageLimit(
            id: "codex.primary",
            name: "Session (5h)",
            percent: percent,
            resetsAt: resetsAt,
            windowDurationMinutes: 300
        )
    }
}

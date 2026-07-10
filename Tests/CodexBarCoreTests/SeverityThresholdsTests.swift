import XCTest
@testable import CodexBarCore

final class SeverityThresholdsTests: XCTestCase {
    func testDefaultsUseSeventyFiveAndNinety() {
        let thresholds = SeverityThresholds(useDefaults: true, warningPercent: 20, criticalPercent: 30)

        XCTAssertEqual(thresholds.resolve(for: limit(percent: 74)), .normal)
        XCTAssertEqual(thresholds.resolve(for: limit(percent: 75)), .warning)
        XCTAssertEqual(thresholds.resolve(for: limit(percent: 90)), .critical)
    }

    func testCustomThresholdsResolveByPercent() {
        let thresholds = SeverityThresholds(useDefaults: false, warningPercent: 40, criticalPercent: 60)

        XCTAssertEqual(thresholds.resolve(for: limit(percent: 39)), .normal)
        XCTAssertEqual(thresholds.resolve(for: limit(percent: 40)), .warning)
        XCTAssertEqual(thresholds.resolve(for: limit(percent: 60)), .critical)
    }

    private func limit(percent: Double) -> UsageLimit {
        UsageLimit(
            id: "codex.primary",
            name: "Session (5h)",
            percent: percent,
            resetsAt: nil,
            windowDurationMinutes: 300
        )
    }
}

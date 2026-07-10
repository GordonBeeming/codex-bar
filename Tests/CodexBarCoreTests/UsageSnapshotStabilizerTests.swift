import Foundation
import XCTest
@testable import CodexBarCore

final class UsageSnapshotStabilizerTests: XCTestCase {
    func testFirstSnapshotIsAccepted() {
        var stabilizer = UsageSnapshotStabilizer()
        let initial = limits(primary: 84, secondary: 13)

        XCTAssertEqual(stabilizer.evaluate(initial), .accepted(initial))
    }

    func testOneOffRegressionIsHeldAndRecoveryIsAccepted() {
        var stabilizer = UsageSnapshotStabilizer()
        let trusted = limits(primary: 84, secondary: 13)
        let transient = limits(primary: 5, secondary: 1, resetShift: 136)
        let recovered = limits(primary: 85, secondary: 13)

        XCTAssertEqual(stabilizer.evaluate(trusted), .accepted(trusted))
        XCTAssertEqual(stabilizer.evaluate(transient), .held(confirmations: 1, required: 3))
        XCTAssertEqual(stabilizer.evaluate(recovered), .accepted(recovered))
    }

    func testRegressionMustPersistAcrossThreeSamplesBeforeAcceptance() {
        var stabilizer = UsageSnapshotStabilizer()
        let trusted = limits(primary: 84, secondary: 13)
        let firstLow = limits(primary: 5, secondary: 1, resetShift: 136)
        let secondLow = limits(primary: 6, secondary: 1, resetShift: 140)
        let thirdLow = limits(primary: 7, secondary: 2, resetShift: 145)

        XCTAssertEqual(stabilizer.evaluate(trusted), .accepted(trusted))
        XCTAssertEqual(stabilizer.evaluate(firstLow), .held(confirmations: 1, required: 3))
        XCTAssertEqual(stabilizer.evaluate(secondLow), .held(confirmations: 2, required: 3))
        XCTAssertEqual(stabilizer.evaluate(thirdLow), .accepted(thirdLow))
    }

    func testExpectedWindowAdvanceAcceptsRealResetImmediately() {
        var stabilizer = UsageSnapshotStabilizer()
        let trusted = limits(primary: 84, secondary: 13)
        let realReset = limits(primary: 5, secondary: 13, primaryResetShift: 18_000)

        XCTAssertEqual(stabilizer.evaluate(trusted), .accepted(trusted))
        XCTAssertEqual(stabilizer.evaluate(realReset), .accepted(realReset))
    }

    func testSmallUsageCorrectionIsNotQuarantined() {
        var stabilizer = UsageSnapshotStabilizer()
        let trusted = limits(primary: 84, secondary: 13)
        let corrected = limits(primary: 80, secondary: 12)

        XCTAssertEqual(stabilizer.evaluate(trusted), .accepted(trusted))
        XCTAssertEqual(stabilizer.evaluate(corrected), .accepted(corrected))
    }

    func testDuplicateLimitIDsDoNotCrashRegressionChecks() {
        var stabilizer = UsageSnapshotStabilizer()
        let trusted = limits(primary: 84, secondary: 13)
        let duplicateTrusted = trusted + [trusted[0]]
        let regressed = limits(primary: 5, secondary: 1, resetShift: 136)
        let duplicateRegression = regressed + [regressed[0]]

        XCTAssertEqual(stabilizer.evaluate(duplicateTrusted), .accepted(duplicateTrusted))
        XCTAssertEqual(stabilizer.evaluate(duplicateRegression), .held(confirmations: 1, required: 3))
        XCTAssertEqual(stabilizer.evaluate(duplicateRegression), .held(confirmations: 2, required: 3))
    }

    func testPlanChangeAcceptsNewUsageImmediately() {
        var stabilizer = UsageSnapshotStabilizer()
        let exhausted = limits(primary: 100, secondary: 17)
        let upgraded = limits(primary: 0, secondary: 0, resetShift: 136)

        XCTAssertEqual(stabilizer.evaluate(exhausted, planType: "plus"), .accepted(exhausted))
        XCTAssertEqual(
            stabilizer.evaluate(upgraded, planType: "prolite"),
            .acceptedPlanChange(upgraded)
        )
    }

    private func limits(
        primary: Double,
        secondary: Double,
        resetShift: TimeInterval = 0,
        primaryResetShift: TimeInterval? = nil
    ) -> [UsageLimit] {
        let primaryBase = Date(timeIntervalSince1970: 1_000_000)
        let secondaryBase = Date(timeIntervalSince1970: 2_000_000)
        return [
            UsageLimit(
                id: "codex.primary",
                name: "Session (5h)",
                percent: primary,
                resetsAt: primaryBase.addingTimeInterval(primaryResetShift ?? resetShift),
                windowDurationMinutes: 300
            ),
            UsageLimit(
                id: "codex.secondary",
                name: "Weekly",
                percent: secondary,
                resetsAt: secondaryBase.addingTimeInterval(resetShift),
                windowDurationMinutes: 10_080
            )
        ]
    }
}

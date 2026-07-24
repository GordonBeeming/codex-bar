import XCTest
@testable import CodexBarCore

final class UsageDisplayModeTests: XCTestCase {
    func testUsedPassesPercentThrough() {
        XCTAssertEqual(UsageDisplayMode.used.displayPercent(usedPercent: 42), 42)
    }

    func testFuelTankShowsRemaining() {
        XCTAssertEqual(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 42), 58)
    }

    func testFuelTankIsFullAtZeroUsage() {
        XCTAssertEqual(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 0), 100)
    }

    func testFuelTankIsEmptyAtFullUsage() {
        XCTAssertEqual(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 100), 0)
    }

    func testFuelTankClampsPercentOverOneHundred() {
        // A limit reported slightly over 100% must read as an empty tank, not a negative one.
        XCTAssertEqual(UsageDisplayMode.fuelTank.displayPercent(usedPercent: 103), 0)
    }

    func testFillFractionMatchesDisplayedPercent() {
        XCTAssertEqual(UsageDisplayMode.used.fillFraction(usedPercent: 25), 0.25)
        XCTAssertEqual(UsageDisplayMode.fuelTank.fillFraction(usedPercent: 25), 0.75)
    }

    func testFillFractionClampsOutOfRangeUsage() {
        XCTAssertEqual(UsageDisplayMode.used.fillFraction(usedPercent: 150), 1)
        XCTAssertEqual(UsageDisplayMode.fuelTank.fillFraction(usedPercent: 150), 0)
    }

    func testMarkerStaysAtPaceWhenCountingUp() {
        XCTAssertEqual(UsageDisplayMode.used.markerFraction(paceFraction: 0.3), 0.3)
    }

    func testMarkerMirrorsWhenDraining() {
        XCTAssertEqual(UsageDisplayMode.fuelTank.markerFraction(paceFraction: 0.3), 0.7)
    }

    func testOverPaceLeavesTankBelowTheMarker() {
        // Usage 60% with 40% of the window elapsed = over pace. In fuel-tank terms the
        // fill (40% left) must land short of the mirrored marker (60% of the window remains).
        let mode = UsageDisplayMode.fuelTank
        let fill = mode.fillFraction(usedPercent: 60)
        let marker = mode.markerFraction(paceFraction: 0.4)
        XCTAssertLessThan(fill, marker)
    }
}

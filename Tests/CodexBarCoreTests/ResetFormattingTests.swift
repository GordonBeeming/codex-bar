import Foundation
import XCTest
@testable import CodexBarCore

final class ResetFormattingTests: XCTestCase {
    func testCountdownHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            ResetFormatting.countdownString(until: now.addingTimeInterval(3_900), now: now),
            "in 1h 5m"
        )
    }

    func testUpdatedAgo() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ResetFormatting.updatedAgoString(since: now.addingTimeInterval(-75), now: now),
            "Updated 1m ago"
        )
    }

    // Reproduces the flicker seen against the live API: the server's resets_at
    // wobbles by under a second between polls, and when the true instant sits near a
    // minute boundary that wobble can land on either side of it. Both sides must
    // still render the same minute.
    func testSubSecondJitterBeforeMinuteBoundaryRoundsUp() {
        // 06:19:59.7 UTC == 16:19:59.7 Brisbane — 0.3s before the 16:20 mark.
        let reset = Date(timeIntervalSince1970: Self.utcEpoch(2026, 7, 7, 6, 19, 0) + 59.7)
        let result = ResetFormatting.localResetString(
            for: reset, now: Self.fixedNow, timeZone: Self.brisbane, locale: Self.enAU
        )
        XCTAssertTrue(result.contains("4:20"), result)
    }

    func testSubSecondJitterAfterMinuteBoundaryStaysPut() {
        // 06:20:00.4 UTC == 16:20:00.4 Brisbane — 0.4s after the 16:20 mark.
        let reset = Date(timeIntervalSince1970: Self.utcEpoch(2026, 7, 7, 6, 20, 0) + 0.4)
        let result = ResetFormatting.localResetString(
            for: reset, now: Self.fixedNow, timeZone: Self.brisbane, locale: Self.enAU
        )
        XCTAssertTrue(result.contains("4:20"), result)
    }

    // Brisbane is UTC+10 with no DST — a fixed, unambiguous zone for the assertions above.
    private static let brisbane = TimeZone(identifier: "Australia/Brisbane")!
    private static let enAU = Locale(identifier: "en_AU")
    // 2026-07-07T00:00:00Z == 10:00 Brisbane, so a 16:20 Brisbane reset is the same local day.
    private static let fixedNow = Date(timeIntervalSince1970: utcEpoch(2026, 7, 7, 0, 0, 0))

    private static func utcEpoch(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!.timeIntervalSince1970
    }
}

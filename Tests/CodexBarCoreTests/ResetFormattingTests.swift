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
}

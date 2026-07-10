import Foundation
import XCTest
@testable import CodexBarCore

final class AppServerProtocolTests: XCTestCase {
    func testParsesAccountAndRateLimitsFromJSONL() throws {
        let jsonl = """
        {"id":0,"result":{"userAgent":"codex"}}
        {"id":1,"result":{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":true}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1783653303},"secondary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1784240103}},"rateLimitsByLimitId":{}}}
        """

        let result = try CodexAppServerResponseParser.parse(Data(jsonl.utf8))

        XCTAssertEqual(result.account.account?.type, "chatgpt")
        XCTAssertEqual(result.account.account?.planType, "plus")
        XCTAssertEqual(result.rateLimits?.rateLimits?.primary?.usedPercent, 25)
        XCTAssertEqual(result.rateLimits?.rateLimits?.secondary?.windowDurationMins, 10_080)
        XCTAssertNil(result.rateLimitsError)
    }

    func testPreservesRateLimitRPCError() throws {
        let jsonl = """
        {"id":1,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}
        {"id":2,"error":{"code":-32000,"message":"ChatGPT authentication required"}}
        """

        let result = try CodexAppServerResponseParser.parse(Data(jsonl.utf8))

        XCTAssertEqual(result.account.account?.type, "apiKey")
        XCTAssertEqual(result.rateLimitsError?.message, "ChatGPT authentication required")
        XCTAssertNil(result.rateLimits)
    }

    func testRejectsMissingAccountResponse() {
        let jsonl = """
        {"id":0,"result":{"userAgent":"codex"}}
        """

        XCTAssertThrowsError(try CodexAppServerResponseParser.parse(Data(jsonl.utf8))) { error in
            XCTAssertEqual(error as? AppServerProtocolError, .missingAccountResponse)
        }
    }
}

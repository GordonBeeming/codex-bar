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

    func testOptionalAccountTokenSummaryAndUnsupportedMethod() throws {
        let base = "{\"id\":1,\"result\":{\"account\":{\"type\":\"chatgpt\"},\"requiresOpenaiAuth\":true}}\n"
        let response = base + "{\"id\":3,\"result\":{\"summary\":{\"lifetimeTokens\":9007199254740993,\"peakDailyTokens\":42},\"dailyUsageBuckets\":[{\"startDate\":\"2026-10-01\",\"tokens\":42}]}}\n"
        let result = try CodexAppServerResponseParser.parse(Data(response.utf8))
        XCTAssertEqual(result.tokenUsage?.summary.lifetimeTokens, 9_007_199_254_740_993)
        XCTAssertEqual(result.tokenUsage?.dailyUsageBuckets?.first?.tokens, 42)
        XCTAssertNil(result.tokenUsageError)
        let unsupported = base + "{\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Unsupported method\"}}\n"
        let fallback = try CodexAppServerResponseParser.parse(Data(unsupported.utf8))
        XCTAssertNil(fallback.tokenUsage)
        XCTAssertEqual(fallback.tokenUsageError?.code, -32601)
        XCTAssertEqual(fallback.account.account?.type, "chatgpt")
    }
}

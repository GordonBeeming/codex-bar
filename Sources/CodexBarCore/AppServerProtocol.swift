import Foundation

public struct RPCError: Decodable, Error, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum AppServerProtocolError: Error, LocalizedError, Equatable {
    case malformedResponse
    case missingAccountResponse
    case accountRequestFailed(RPCError)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Codex returned a malformed response"
        case .missingAccountResponse:
            return "Codex didn't return account information"
        case let .accountRequestFailed(error):
            return "Codex account request failed: \(error.message)"
        }
    }
}

public enum CodexAppServerResponseParser {
    public static func parse(_ data: Data) throws -> CodexProbeResult {
        let decoder = JSONDecoder()
        var account: AccountReadResult?
        var accountError: RPCError?
        var rateLimits: RateLimitsResult?
        var rateLimitsError: RPCError?
        var sawJSON = false

        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let header = try? decoder.decode(ResponseHeader.self, from: Data(line)) else {
                continue
            }
            sawJSON = true

            switch header.id {
            case 1:
                if let error = header.error {
                    accountError = error
                } else if let response = try? decoder.decode(AccountResponse.self, from: Data(line)) {
                    account = response.result
                }
            case 2:
                if let error = header.error {
                    rateLimitsError = error
                } else if let response = try? decoder.decode(RateLimitsResponse.self, from: Data(line)) {
                    rateLimits = response.result
                }
            default:
                continue
            }
        }

        guard sawJSON else { throw AppServerProtocolError.malformedResponse }
        if let accountError {
            throw AppServerProtocolError.accountRequestFailed(accountError)
        }
        guard let account else { throw AppServerProtocolError.missingAccountResponse }
        return CodexProbeResult(
            account: account,
            rateLimits: rateLimits,
            rateLimitsError: rateLimitsError
        )
    }

    private struct ResponseHeader: Decodable {
        let id: Int?
        let error: RPCError?
    }

    private struct AccountResponse: Decodable {
        let result: AccountReadResult
    }

    private struct RateLimitsResponse: Decodable {
        let result: RateLimitsResult
    }
}

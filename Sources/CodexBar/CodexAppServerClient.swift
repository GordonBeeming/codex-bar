import CodexBarCore
import Foundation

struct UsageSnapshot: Sendable {
    let limits: [UsageLimit]
    let planType: String?
    let rateLimits: RateLimitsResult
    let tokenUsage: AccountTokenUsage?
    let tokenUsageError: String?
}

enum CodexClientError: Error, LocalizedError {
    case notSignedIn
    case chatGPTSignInRequired
    case rateLimitsUnavailable(String?)
    case processFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign into Codex with ChatGPT"
        case .chatGPTSignInRequired:
            return "ChatGPT sign-in is required to read plan limits"
        case let .rateLimitsUnavailable(message):
            return message.map { "Couldn't read Codex limits: \($0)" } ?? "Codex limits aren't available"
        case .processFailed:
            return "Codex app-server stopped before returning usage"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage(includeTokenUsage: Bool) async throws -> UsageSnapshot
}

struct CodexAppServerClient: UsageFetching {
    private let locator = CodexExecutableLocator()

    func fetchUsage(includeTokenUsage: Bool = false) async throws -> UsageSnapshot {
        let executable = try locator.locate()
        let data = try await Task.detached(priority: .utility) {
            try Self.runProbe(executable: executable, includeTokenUsage: includeTokenUsage)
        }.value
        let probe = try CodexAppServerResponseParser.parse(data)

        guard let account = probe.account.account else {
            throw CodexClientError.notSignedIn
        }
        guard account.type == "chatgpt" else {
            throw CodexClientError.chatGPTSignInRequired
        }
        guard let rateLimits = probe.rateLimits else {
            throw CodexClientError.rateLimitsUnavailable(probe.rateLimitsError?.message)
        }

        let limits = UsageLimitMapper.limits(from: rateLimits)
        guard !limits.isEmpty else {
            throw CodexClientError.rateLimitsUnavailable(nil)
        }

        return UsageSnapshot(
            limits: limits,
            planType: UsageLimitMapper.planType(from: rateLimits, account: account),
            rateLimits: rateLimits, tokenUsage: probe.tokenUsage, tokenUsageError: probe.tokenUsageError?.message
        )
    }

    static func runProbe(executable: URL, includeTokenUsage: Bool, optionalResponseTimeout: TimeInterval = 2) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = environment["PATH"]
            .flatMap { $0.isEmpty ? nil : "\(executableDirectory):\($0)" } ?? executableDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning {
                process.terminate()
            }
        }

        let initialize: [String: Any] = [
            "method": "initialize",
            "id": 0,
            "params": [
                "capabilities": ["experimentalApi": includeTokenUsage],
                "clientInfo": [
                    "name": "codex_bar",
                    "title": "CodexBar",
                    "version": "0.1.0"
                ]
            ]
        ]
        try write([initialize], to: input.fileHandleForWriting)

        var response = Data()
        guard read(until: [0], from: output.fileHandleForReading, into: &response) else {
            throw CodexClientError.processFailed
        }

        var requests: [[String: Any]] = [
            ["method": "initialized", "params": [:]],
            ["method": "account/read", "id": 1, "params": ["refreshToken": false]],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]]
        ]
        if includeTokenUsage { requests.append(["method": "account/usage/read", "id": 3, "params": [:]]) }
        try write(requests, to: input.fileHandleForWriting)

        guard read(until: [1, 2], from: output.fileHandleForReading, into: &response) else {
            throw CodexClientError.processFailed
        }
        if includeTokenUsage {
            let optionalTimeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + optionalResponseTimeout, execute: optionalTimeout)
            defer { optionalTimeout.cancel() }
            if !read(until: [3], from: output.fileHandleForReading, into: &response) {
                let error: [String: Any] = ["id": 3, "error": ["code": -1, "message": "Account token usage request did not complete"]]
                response.append(0x0A)
                response.append(try JSONSerialization.data(withJSONObject: error))
                response.append(0x0A)
            }
        }

        try input.fileHandleForWriting.close()
        response.append(output.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()

        guard process.terminationStatus == 0 || !response.isEmpty else {
            throw CodexClientError.processFailed
        }
        return response
    }

    private static func write(_ messages: [[String: Any]], to handle: FileHandle) throws {
        let request = try messages.reduce(into: Data()) { data, message in
            data.append(try JSONSerialization.data(withJSONObject: message))
            data.append(0x0A)
        }
        try handle.write(contentsOf: request)
    }

    private static func read(
        until expectedIDs: Set<Int>,
        from handle: FileHandle,
        into response: inout Data
    ) -> Bool {
        while !expectedIDs.isSubset(of: responseIDs(in: response)) {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return false }
            response.append(chunk)
        }
        return true
    }

    private static func responseIDs(in data: Data) -> Set<Int> {
        Set(data.split(separator: 0x0A).compactMap { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let dictionary = object as? [String: Any],
                let id = dictionary["id"] as? Int
            else {
                return nil
            }
            return id
        })
    }
}

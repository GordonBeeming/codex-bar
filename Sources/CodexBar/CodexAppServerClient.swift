import CodexBarCore
import Foundation

struct UsageSnapshot: Sendable {
    let limits: [UsageLimit]
    let planType: String?
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

struct CodexAppServerClient: Sendable {
    private let locator = CodexExecutableLocator()

    func fetchUsage() async throws -> UsageSnapshot {
        let executable = try locator.locate()
        let data = try await Task.detached(priority: .utility) {
            try Self.runProbe(executable: executable)
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
            planType: UsageLimitMapper.planType(from: rateLimits, account: account)
        )
    }

    private static func runProbe(executable: URL) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
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
        defer { timeout.cancel() }

        let initialize: [String: Any] = [
            "method": "initialize",
            "id": 0,
            "params": [
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

        try write(
            [
                ["method": "initialized", "params": [:]],
                ["method": "account/read", "id": 1, "params": ["refreshToken": false]],
                ["method": "account/rateLimits/read", "id": 2, "params": [:]]
            ],
            to: input.fileHandleForWriting
        )

        guard read(until: [1, 2], from: output.fileHandleForReading, into: &response) else {
            throw CodexClientError.processFailed
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

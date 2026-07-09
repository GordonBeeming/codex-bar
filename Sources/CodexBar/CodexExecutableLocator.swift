import Foundation

struct CodexExecutableLocator: Sendable {
    enum LocatorError: Error, LocalizedError {
        case notFound

        var errorDescription: String? {
            "Codex CLI wasn't found"
        }
    }

    func locate() throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser

        var candidates: [URL] = []
        if let configured = environment["CODEX_PATH"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }

        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }

        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appending(path: ".local/bin/codex"),
            home.appending(path: ".volta/bin/codex"),
            home.appending(path: ".nvm/current/bin/codex")
        ]

        candidates += executables(
            beneath: home.appending(path: ".local/share/fnm/node-versions"),
            suffix: "installation/bin/codex"
        )
        candidates += executables(
            beneath: home.appending(path: ".local/state/fnm_multishells"),
            suffix: "bin/codex"
        )

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw LocatorError.notFound
    }

    private func executables(beneath root: URL, suffix: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .sorted { lhs, rhs in
                let lhsDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let rhsDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
            .map { $0.appending(path: suffix) }
    }
}

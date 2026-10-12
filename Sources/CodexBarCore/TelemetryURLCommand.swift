import Foundation

/// Tracking settings a `codexbar://telemetry` URL asks to change. `nil` means leave as is.
public struct TelemetrySettingsChange: Equatable, Sendable {
    public var enabled: Bool?
    public var intervalMinutes: Int?
    public var retentionDays: Int?
    public var directory: String?

    public init(enabled: Bool? = nil, intervalMinutes: Int? = nil, retentionDays: Int? = nil, directory: String? = nil) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.retentionDays = retentionDays
        self.directory = directory
    }

    /// One line per value that actually changes, old value first, for the confirmation.
    public func changeLines(from current: TelemetryConfiguration) -> [String] {
        var lines: [String] = []
        if let enabled, enabled != current.enabled {
            lines.append("Tracking: \(current.enabled ? "on" : "off") → \(enabled ? "on" : "off")")
        }
        if let intervalMinutes, intervalMinutes != current.intervalMinutes {
            lines.append("Interval: \(current.intervalMinutes) min → \(intervalMinutes) min")
        }
        if let retentionDays, retentionDays != current.retentionDays {
            lines.append("Retention: \(Self.retention(current.retentionDays)) → \(Self.retention(retentionDays))")
        }
        if let directory, directory != current.directory.path {
            lines.append("Folder: \(current.directory.path) → \(directory)")
        }
        return lines
    }

    private static func retention(_ days: Int) -> String {
        switch days {
        case TelemetryConfiguration.unlimitedRetentionDays: "forever"
        case 1: "1 day"
        default: "\(days) days"
        }
    }
}

public enum TelemetryURLCommand: Equatable, Sendable {
    case telemetry(TelemetrySettingsChange)
    case settings

    public struct Rejection: LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public static let scheme = "codexbar"

    /// Reads a `codexbar://` URL. Any invalid value rejects the whole request, because any
    /// app or web page can open the URL and half-applying it would be a surprise.
    public static func parse(_ url: URL) throws -> TelemetryURLCommand {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Rejection(reason: "This isn't a CodexBar link.")
        }
        switch components.host?.lowercased() {
        case "settings":
            return .settings
        case "telemetry":
            return .telemetry(try change(from: components.queryItems ?? []))
        default:
            throw Rejection(reason: "CodexBar doesn't know the command “\(components.host ?? "")”.")
        }
    }

    private static func change(from items: [URLQueryItem]) throws -> TelemetrySettingsChange {
        let known = ["enabled", "interval", "retention", "folder"]
        var values: [String: String] = [:]
        for item in items where known.contains(item.name) {
            guard values[item.name] == nil else {
                throw Rejection(reason: "“\(item.name)” is given more than once.")
            }
            values[item.name] = item.value ?? ""
        }
        var change = TelemetrySettingsChange()
        if let value = values["enabled"] {
            switch value.lowercased() {
            case "1", "true": change.enabled = true
            case "0", "false": change.enabled = false
            default: throw Rejection(reason: "enabled must be 1 or 0, not “\(value)”.")
            }
        }
        if let value = values["interval"] {
            guard let minutes = Int(value), (1...1_440).contains(minutes) else {
                throw Rejection(reason: "interval must be a whole number of minutes from 1 to 1440, not “\(value)”.")
            }
            change.intervalMinutes = minutes
        }
        if let value = values["retention"] {
            guard let days = Int(value),
                  days == TelemetryConfiguration.unlimitedRetentionDays || (1...3_650).contains(days) else {
                throw Rejection(reason: "retention must be 0 (forever) or a whole number of days from 1 to 3650, not “\(value)”.")
            }
            change.retentionDays = days
        }
        if let value = values["folder"] {
            guard value.hasPrefix("/") else {
                throw Rejection(reason: "folder must be an absolute path, not “\(value)”.")
            }
            change.directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        }
        return change
    }
}

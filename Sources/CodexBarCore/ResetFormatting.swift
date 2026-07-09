import Foundation

public enum ResetFormatting {
    public static func localResetString(
        for date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let time = date.formatted(
            Date.FormatStyle(locale: locale, timeZone: timeZone)
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute()
        )
        let today = calendar.startOfDay(for: now)

        guard
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
            let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today),
            let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)
        else {
            return time
        }

        if date >= today && date < tomorrow {
            return time
        }
        if date >= tomorrow && date < dayAfterTomorrow {
            return "Tomorrow \(time)"
        }
        if date >= dayAfterTomorrow && date < nextWeek {
            let weekday = date.formatted(
                Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated)
            )
            return "\(weekday) \(time)"
        }

        let day = date.formatted(
            Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
        )
        return "\(day) \(time)"
    }

    public static func countdownString(until date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 0 { return "resetting…" }
        if interval < 60 { return "in <1m" }
        if interval < 3_600 { return "in \(Int(interval / 60))m" }
        if interval < 172_800 {
            let hours = Int(interval / 3_600)
            let minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
            return "in \(hours)h \(minutes)m"
        }
        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        return "in \(days)d \(hours)h"
    }

    public static func updatedAgoString(since date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 10 { return "Updated just now" }
        if interval < 60 { return "Updated \(Int(interval))s ago" }
        if interval < 3_600 { return "Updated \(Int(interval / 60))m ago" }
        return "Updated \(Int(interval / 3_600))h ago"
    }
}

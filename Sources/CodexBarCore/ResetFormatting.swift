import Foundation

public enum ResetFormatting {
    public static func localResetString(
        for date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        // The API's resets_at carries a little sub-second jitter around the true instant
        // (server-side recomputation noise) that's invisible at the minute granularity
        // this renders at — except when the true instant sits within a second of a
        // minute boundary, where the same reset can otherwise flip its displayed minute
        // from one poll to the next (e.g. 10:09 one refresh, 10:10 the next). Rounding
        // first makes the display stable regardless of which side of the boundary a
        // given poll's jitter lands on.
        let date = roundedToMinute(date)

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

    private static func roundedToMinute(_ date: Date) -> Date {
        let seconds = (date.timeIntervalSinceReferenceDate / 60).rounded() * 60
        return Date(timeIntervalSinceReferenceDate: seconds)
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

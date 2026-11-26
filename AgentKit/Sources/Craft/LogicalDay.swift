import Foundation

/// Single source of truth for Clio's logical day across memory budgets, processed watermarks,
/// nightly review (`21:00–05:00`), promotion, diary, and catch-up triggers.
///
/// The logical day rolls over at `04:00` local time using calendar-component arithmetic rather than
/// fixed-second subtraction, preventing off-by-one drift across DST transitions and timezone changes.
public enum LogicalDay: Sendable {
    public static let defaultBoundaryHour: Int = 4

    /// Returns the `yyyy-MM-dd` logical day string for `date`.
    /// Hours `00:00..<boundaryHour` belong to the previous calendar day.
    public static func day(
        of date: Date,
        boundaryHour: Int = defaultBoundaryHour,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let startOfDay = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return formatYMD(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
        }
        let hour = components.hour ?? 0
        let clampedBoundary = max(0, min(23, boundaryHour))
        let resolvedDate: Date
        if hour < clampedBoundary {
            resolvedDate = calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
        } else {
            resolvedDate = startOfDay
        }
        let finalParts = calendar.dateComponents([.year, .month, .day], from: resolvedDate)
        return formatYMD(
            year: finalParts.year ?? year,
            month: finalParts.month ?? month,
            day: finalParts.day ?? day
        )
    }

    /// Steps backward `days` calendar days from `date`'s logical day using calendar arithmetic (DST-safe).
    public static func daysBack(
        _ count: Int,
        from date: Date,
        boundaryHour: Int = defaultBoundaryHour,
        calendar: Calendar = .current
    ) -> String {
        let anchorDay = day(of: date, boundaryHour: boundaryHour, calendar: calendar)
        guard count != 0, let parsed = parseYMD(anchorDay) else {
            return anchorDay
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let anchorDate = utc.date(from: DateComponents(year: parsed.year, month: parsed.month, day: parsed.day)),
              let shifted = utc.date(byAdding: .day, value: -count, to: anchorDate) else {
            return anchorDay
        }
        let parts = utc.dateComponents([.year, .month, .day], from: shifted)
        return formatYMD(year: parts.year ?? parsed.year, month: parts.month ?? parsed.month, day: parts.day ?? parsed.day)
    }

    /// Nightly window (`21:00–05:00`) day key shared by `MemoryNight` and `diaryIfDue`.
    /// Hours `00:00..<05:00` belong to the night that started the evening before, preventing
    /// a `04:00` split inside the single `21:00–05:00` background window.
    public static func nightlyReviewDay(
        at date: Date,
        catchUp: Bool = false,
        boundaryHour: Int = defaultBoundaryHour,
        calendar: Calendar = .current
    ) -> String? {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let hour = components.hour ?? 0
        if hour >= 21 {
            return day(of: date, boundaryHour: boundaryHour, calendar: calendar)
        }
        if hour < 5 {
            guard let year = components.year,
                  let month = components.month,
                  let calDay = components.day,
                  let startOfDay = calendar.date(from: DateComponents(year: year, month: month, day: calDay)),
                  let previousDay = calendar.date(byAdding: .day, value: -1, to: startOfDay) else {
                return day(of: date, boundaryHour: boundaryHour, calendar: calendar)
            }
            let prevParts = calendar.dateComponents([.year, .month, .day], from: previousDay)
            return formatYMD(
                year: prevParts.year ?? year,
                month: prevParts.month ?? month,
                day: prevParts.day ?? calDay
            )
        }
        guard catchUp else { return nil }
        return daysBack(1, from: date, boundaryHour: boundaryHour, calendar: calendar)
    }

    /// Normalizes legacy `yyyy-MM-dd` or `yyyy/M/d` day keys into canonical zero-padded `yyyy-MM-dd`.
    public static func normalizeLegacyDayKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "/", with: "-")
        guard let parsed = parseYMD(normalized) else { return nil }
        return formatYMD(year: parsed.year, month: parsed.month, day: parsed.day)
    }

    private static func parseYMD(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), (1970...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else {
            return nil
        }
        return (year, month, day)
    }

    private static func formatYMD(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

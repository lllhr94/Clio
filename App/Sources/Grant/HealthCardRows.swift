import Foundation

/// The order of older tools predates the persisted format marker. Dates in a report
/// span no more than 30 days, so the direction is unambiguous across New Year's Day.
enum HealthCardRows {
    static let newestFirst = "clio.health.newest-first.v1"

    static func newest(_ text: String, format: String?) -> [Substring] {
        var lines = text.split(separator: "\n")
        if lines.last == "……" {
            lines.removeLast()
            // The saved prefix may have stopped in the middle of a number.
            if !lines.isEmpty { lines.removeLast() }
        }
        let rows = lines.filter { $0.contains("：") && !$0.hasPrefix("（") }
        if format == newestFirst { return Array(rows.prefix(3)) }
        let dates = rows.compactMap(day)
        var ascending = false
        for (left, right) in zip(dates, dates.dropFirst()) where left != right {
            let forward = (right - left + 372) % 372
            ascending = forward < 186
            break
        }
        return ascending ? Array(rows.suffix(3).reversed()) : Array(rows.prefix(3))
    }

    private static func day(_ row: Substring) -> Int? {
        guard let monthEnd = row.firstIndex(of: "月"), let dayEnd = row.firstIndex(of: "日"), monthEnd < dayEnd,
              let month = Int(row[..<monthEnd]), (1...12).contains(month),
              let day = Int(row[row.index(after: monthEnd)..<dayEnd]), (1...31).contains(day) else { return nil }
        return (month - 1) * 31 + day - 1
    }
}

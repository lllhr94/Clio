import Foundation

/// 定时: something a companion does again and again at a set time (every morning, on weekdays). The phone cannot
/// wake an app on the dot, so at that time a notification comes, and the work starts once Clio is open.
public struct Routine: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var botId: String
    public var title: String
    /// What the companion is asked, each time.
    public var prompt: String
    public var hour: Int
    public var minute: Int
    /// Days it runs on, Monday = 1 … Sunday = 7. Empty: every day.
    public var days: [Int]
    public var on: Bool
    /// Seconds since 1970.
    public var created: Double
    public var lastRun: Double?

    public init(id: String = UUID().uuidString, botId: String, title: String, prompt: String, hour: Int, minute: Int, days: [Int] = [], on: Bool = true, created: Double = Date().timeIntervalSince1970, lastRun: Double? = nil) {
        self.id = id
        self.botId = botId
        self.title = title
        self.prompt = prompt
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
        self.days = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        self.on = on
        self.created = created
        self.lastRun = lastRun
    }

    /// Monday = 1 … Sunday = 7, from Calendar's Sunday = 1 … Saturday = 7.
    static func day(of date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    /// Calendar's numbering (Sunday = 1) for one of ours.
    public static func weekday(_ day: Int) -> Int { day == 7 ? 1 : day + 1 }

    func runs(on date: Date, calendar: Calendar) -> Bool {
        days.isEmpty || days.contains(Self.day(of: date, calendar: calendar))
    }

    /// The set time on the day of `date`.
    func time(on date: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// The next time after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date), runs(on: day, calendar: calendar),
                  let at = time(on: day, calendar: calendar), at > date else { continue }
            return at
        }
        return nil
    }

    /// The latest set time that has come and not been done, and how many before it were missed (counted over two weeks).
    public func due(now: Date, calendar: Calendar = .current) -> (at: Date, missed: Int)? {
        guard on else { return nil }
        let since = Date(timeIntervalSince1970: lastRun ?? created)
        var found: [Date] = []
        for offset in 0...14 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now), runs(on: day, calendar: calendar),
                  let at = time(on: day, calendar: calendar), at <= now, at > since else { continue }
            found.append(at)
        }
        guard let latest = found.first else { return nil }
        return (latest, found.count - 1)
    }

    /// 「每天 08:30」「工作日 08:30」「周一、周三 21:00」
    public var when: String {
        let clock = String(format: "%02d:%02d", hour, minute)
        let names = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        switch days {
        case [], [1, 2, 3, 4, 5, 6, 7]: return "每天 \(clock)"
        case [1, 2, 3, 4, 5]: return "工作日 \(clock)"
        case [6, 7]: return "周末 \(clock)"
        default: return days.map { names[$0] }.joined(separator: "、") + " \(clock)"
        }
    }

    /// Reads days as a person or a model writes them: 每天, 工作日, 周末, 「1,3,5」, 「周一 周三」.
    public static func days(from words: String?) -> [Int] {
        let text = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains("每天") || text.lowercased() == "daily" { return [] }
        if text.contains("工作日") || text.lowercased() == "weekdays" { return [1, 2, 3, 4, 5] }
        if text.contains("周末") || text.lowercased() == "weekends" { return [6, 7] }
        let names: [(String, Int)] = [("一", 1), ("二", 2), ("三", 3), ("四", 4), ("五", 5), ("六", 6), ("日", 7), ("天", 7)]
        var found: [Int] = []
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",，、 ;；")) where !part.isEmpty {
            if let number = Int(part), (1...7).contains(number) {
                found.append(number)
            } else if let name = names.first(where: { part.hasSuffix($0.0) }) {
                found.append(name.1)
            }
        }
        return Array(Set(found)).sorted()
    }

    /// 「08:30」「8:30」「8点半」 into hour and minute.
    public static func clock(_ words: String?) -> (hour: Int, minute: Int)? {
        var text = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "点半", with: ":30").replacingOccurrences(of: "点", with: ":").replacingOccurrences(of: "：", with: ":")
        let parts = text.split(separator: ":").map { String($0).trimmingCharacters(in: CharacterSet.decimalDigits.inverted) }
        guard var hour = parts.first.flatMap({ Int($0) }), (0...23).contains(hour) else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        guard (0...59).contains(minute) else { return nil }
        if hour < 12, ["下午", "晚上", "傍晚", "夜里"].contains(where: { text.contains($0) }) { hour += 12 }
        return (hour, minute)
    }
}

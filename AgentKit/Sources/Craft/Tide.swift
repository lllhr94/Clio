import Foundation

/// 潮水: every day the tide leaves one small thing on the desk. Nothing is spent on it, nothing runs out,
/// and a day missed is not lost: what came while you were away is still there (up to a week), the rest goes
/// straight into the collection.
public enum Tide {
    public struct Find: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// The day it came, 2026-11-18.
        public var day: String
        public var name: String
        /// An SF Symbol.
        public var symbol: String
        /// What the whale says, picking it up.
        public var line: String
        /// Picked up by hand (false: the tide left it while you were away and it was put away for you).
        public var picked: Bool

        public var id: String { day }

        public init(day: String, name: String, symbol: String, line: String, picked: Bool = false) {
            self.day = day
            self.name = name
            self.symbol = symbol
            self.line = line
            self.picked = picked
        }
    }

    /// Ordinary days.
    static let catalog: [(name: String, symbol: String, line: String)] = [
        ("一枚螺旋贝", "hurricane", "转了好多圈的小贝壳，像把一段路卷起来收着。"),
        ("半片海玻璃", "diamond", "被浪磨圆了边，对着光是淡淡的绿。"),
        ("一粒圆石子", "circle.fill", "圆得刚好能握在手心，暖暖的。"),
        ("一根白羽毛", "leaf", "不知道是哪只海鸟掉的，轻得像没拿着。"),
        ("一只小海星", "star.fill", "它在沙里躺着晒太阳，我只借来看一眼。"),
        ("一个漂流瓶", "waterbottle", "瓶子里有张纸条，写着：今天也辛苦了。"),
        ("一片银杏叶", "leaf.fill", "从很远的岸边漂过来的，还是金黄色。"),
        ("一颗松果", "tree", "海边也会有松果，大概是风送来的。"),
        ("一小撮星砂", "sparkles", "细细的，每一粒都是一颗小星星的形状。"),
        ("一朵海葵花", "camera.macro", "碰一下就合上了，害羞得很。"),
        ("一枚旧纽扣", "smallcircle.filled.circle", "不知道从谁的大衣上掉下来，还很新。"),
        ("一段麻绳", "lasso", "可以拿来系东西，我先替你收着。"),
        ("一只纸船", "sailboat", "不知道谁折的，竟然漂到了这里。"),
        ("一片月光贝", "moon.fill", "白白的，像把一小块月亮留下了。"),
        ("一颗玻璃弹珠", "circle.hexagongrid.fill", "里面有一道蓝色的花纹，像一小片海。"),
        ("一枚书签", "bookmark.fill", "夹在哪一页都好，留着慢慢看。"),
        ("一只小螃蟹", "tortoise.fill", "它横着走过来打了个招呼，又走了。我只记下了它。"),
        ("一片珊瑚", "tree.fill", "已经褪成白色了，摸起来有点粗。"),
        ("一束海草", "wind", "湿湿的，还带着潮水的味道。"),
        ("一枚邮票", "envelope.fill", "盖着看不清的邮戳，从哪里寄来的呢。"),
        ("一个小铃铛", "bell.fill", "晃一晃，叮的一声，很轻。"),
        ("一块海盐", "cube.fill", "亮晶晶的，舔一下大概是咸的。"),
        ("一片雨后的云", "cloud.fill", "这个不能真的捡，就记在本子上吧。"),
        ("一颗红豆", "heart.fill", "小小一颗，红得很认真。"),
    ]

    /// Days of the year that bring something of their own, by month-day.
    static let feasts: [String: (name: String, symbol: String, line: String)] = [
        "01-01": ("一页新日历", "calendar", "新的一年第一页，干干净净的。"),
        "02-14": ("一枚心形石", "heart.circle.fill", "天然长成心形的石头，难得。"),
        "06-01": ("一颗水果糖", "gift.fill", "今天大家都可以当小孩。"),
        "10-01": ("一面小旗子", "flag.fill", "插在沙堆上，风一吹就飘。"),
        "12-25": ("一颗小松球", "snowflake", "挂起来就是今天的装饰了。"),
    ]

    /// The day the tide belongs to. It turns at five in the morning, so a late night still counts as the day before.
    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let shifted = date.addingTimeInterval(-5 * 3600)
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What the tide brings on `day`. The same day and seed always bring the same thing, however often you look.
    public static func find(on day: String, seed: String) -> Find {
        if let feast = feasts[String(day.suffix(5))] {
            return Find(day: day, name: feast.name, symbol: feast.symbol, line: feast.line)
        }
        let item = catalog[Int(fnv("\(seed)|\(day)") % UInt64(catalog.count))]
        return Find(day: day, name: item.name, symbol: item.symbol, line: item.line)
    }

    /// The days after `last` (not included) up to `today` (included), oldest first. Without `last`, only today.
    public static func days(after last: String?, through today: String) -> [String] {
        guard let last, let start = date(last), let end = date(today), start < end else { return last == nil ? [today] : [] }
        var days: [String] = []
        var cursor = start
        while let next = utc.date(byAdding: .day, value: 1, to: cursor), next <= end {
            days.append(stamp(next))
            cursor = next
            if days.count > 3660 { break }
        }
        return days
    }

    /// Of the days the tide came while you were away, the newest `kept` wait on the sand; the older ones are put away for you.
    public static func arrivals(after last: String?, through today: String, seed: String, kept: Int = 7) -> (waiting: [Find], putAway: [Find]) {
        let finds = days(after: last, through: today).map { find(on: $0, seed: seed) }
        let split = max(0, finds.count - kept)
        return (Array(finds[split...]), Array(finds[..<split]))
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func stamp(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// FNV-1a: a hash that stays the same between launches (Swift's own does not).
    public static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

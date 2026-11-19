import Foundation

/// One way to say how long something took, everywhere: 「8 秒」「1 分 05 秒」「1 小时 02 分」; and the running clock 「1:05」.
enum Clock {
    static func said(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return String(format: "%d 分 %02d 秒", s / 60, s % 60) }
        return String(format: "%d 小时 %02d 分", s / 3600, (s % 3600) / 60)
    }

    static func running(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

import AgentKit
import Foundation
import HealthKit

/// 健康: reads from Apple Health — never writes. Works only when the app was signed with the HealthKit entitlement;
/// otherwise every call says so plainly instead of failing quietly.
enum Health {
    static let store = HKHealthStore()

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Whether the system question has been shown. iOS keeps the answer to itself.
    static var asked: Bool { UserDefaults.standard.bool(forKey: "health.asked") }

    enum Kind: String, CaseIterable {
        case steps, distance, energy, heart, resting, sleep, weight

        var title: String {
            switch self {
            case .steps: "步数"
            case .distance: "步行跑步距离"
            case .energy: "活动能量"
            case .heart: "心率"
            case .resting: "静息心率"
            case .sleep: "睡眠"
            case .weight: "体重"
            }
        }

        var type: HKObjectType {
            switch self {
            case .steps: HKQuantityType(.stepCount)
            case .distance: HKQuantityType(.distanceWalkingRunning)
            case .energy: HKQuantityType(.activeEnergyBurned)
            case .heart: HKQuantityType(.heartRate)
            case .resting: HKQuantityType(.restingHeartRate)
            case .sleep: HKCategoryType(.sleepAnalysis)
            case .weight: HKQuantityType(.bodyMass)
            }
        }
    }

    /// Shows the system question. Returns a sentence when something stands in the way.
    @discardableResult
    static func authorize() async -> String? {
        guard available else { return "这台设备没有「健康」。" }
        do {
            try await store.requestAuthorization(toShare: [], read: Set(Kind.allCases.map(\.type)))
            UserDefaults.standard.set(true, forKey: "health.asked")
            return nil
        } catch {
            return explain(error)
        }
    }

    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("entitlement") {
            return "这个安装包签名时没带「健康」权限（HealthKit），iOS 不让读。换一个带 HealthKit 的证书重新签名就能用；步数也可以先用「步数」本事从运动协处理器读。"
        }
        return "读不了「健康」：\(text)"
    }

    struct Day {
        var date: Date
        var values: [Kind: String] = [:]
    }

    /// Day by day, oldest first, for the kinds asked.
    static func days(_ count: Int, kinds: [Kind]) async throws -> [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }
        let end = Date()
        var days: [Day] = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map { Day(date: $0) } }
        func put(_ kind: Kind, _ date: Date, _ value: String) {
            if let index = days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) { days[index].values[kind] = value }
        }
        for kind in kinds {
            switch kind {
            case .steps, .distance, .energy:
                let type = kind.type as! HKQuantityType
                let unit: HKUnit = kind == .steps ? .count() : kind == .distance ? .meterUnit(with: .kilo) : .kilocalorie()
                let stats = try await collection(type, options: .cumulativeSum, from: start, to: end)
                stats.enumerateStatistics(from: start, to: end) { item, _ in
                    guard let sum = item.sumQuantity()?.doubleValue(for: unit) else { return }
                    let shown = kind == .steps ? "\(Int(sum)) 步" : kind == .distance ? String(format: "%.1f 公里", sum) : "\(Int(sum)) 千卡"
                    put(kind, item.startDate, shown)
                }
            case .heart, .resting:
                let type = kind.type as! HKQuantityType
                let unit = HKUnit.count().unitDivided(by: .minute())
                let stats = try await collection(type, options: [.discreteAverage, .discreteMin, .discreteMax], from: start, to: end)
                stats.enumerateStatistics(from: start, to: end) { item, _ in
                    guard let average = item.averageQuantity()?.doubleValue(for: unit) else { return }
                    if kind == .resting {
                        put(kind, item.startDate, "\(Int(average.rounded())) 次/分")
                    } else {
                        let low = item.minimumQuantity()?.doubleValue(for: unit) ?? average
                        let high = item.maximumQuantity()?.doubleValue(for: unit) ?? average
                        put(kind, item.startDate, "平均 \(Int(average.rounded()))，\(Int(low))–\(Int(high)) 次/分")
                    }
                }
            case .weight:
                let stats = try await collection(HKQuantityType(.bodyMass), options: .mostRecent, from: start, to: end)
                stats.enumerateStatistics(from: start, to: end) { item, _ in
                    guard let kilos = item.mostRecentQuantity()?.doubleValue(for: .gramUnit(with: .kilo)) else { return }
                    put(kind, item.startDate, String(format: "%.1f 公斤", kilos))
                }
            case .sleep:
                let nights = try await sleep(from: calendar.date(byAdding: .hour, value: -12, to: start) ?? start, to: end)
                for (date, minutes) in nights where minutes > 0 {
                    put(kind, date, "\(minutes / 60) 小时 \(minutes % 60) 分")
                }
            }
        }
        return days
    }

    private static func collection(_ type: HKQuantityType, options: HKStatisticsOptions, from start: Date, to end: Date) async throws -> HKStatisticsCollection {
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end))
        let query = HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: options, anchorDate: Calendar.current.startOfDay(for: start), intervalComponents: DateComponents(day: 1))
        return try await query.result(for: store)
    }

    /// Minutes asleep per night, counted on the morning the night ended. Overlapping records (phone and watch) count once.
    private static func sleep(from start: Date, to end: Date) async throws -> [(Date, Int)] {
        let predicate = HKSamplePredicate.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end))
        let query = HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = try await query.result(for: store)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var spans: [(Date, Date)] = []
        for sample in samples where asleep.contains(sample.value) {
            if let last = spans.last, sample.startDate <= last.1 {
                spans[spans.count - 1].1 = max(last.1, sample.endDate)
            } else {
                spans.append((sample.startDate, sample.endDate))
            }
        }
        var byDay: [Date: Int] = [:]
        let calendar = Calendar.current
        for (from, to) in spans {
            byDay[calendar.startOfDay(for: to), default: 0] += Int(to.timeIntervalSince(from) / 60)
        }
        return byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

enum HealthTools {
    static func all() -> [AgentTool] {
        guard Health.available else { return [] }
        let names = Health.Kind.allCases.map { "\($0.rawValue)（\($0.title)）" }.joined(separator: "、")
        return [
            DeskTool(name: "health_read", description: "读「健康」里的数据，按天列出。kinds 可选：\(names)，留空就读步数、睡眠、静息心率和活动能量。只读，不会写进「健康」。", parameters: [
                "type": "object",
                "properties": [
                    "kinds": ["type": "array", "items": ["type": "string"]],
                    "days": ["type": "number", "description": "最近几天，默认 1（今天），最多 30"],
                ],
            ], label: { arguments in
                let days = Int(arguments["days"]?.number ?? 1)
                return "健康：看看" + (days <= 1 ? "今天" : "最近 \(days) 天")
            }) { arguments in
                if !Health.asked, let problem = await Health.authorize() { return ToolOutput(problem, isError: true) }
                let wanted = (arguments["kinds"]?.array ?? []).compactMap { $0.string.flatMap(Health.Kind.init(rawValue:)) }
                let kinds: [Health.Kind] = wanted.isEmpty ? [.steps, .sleep, .resting, .energy] : wanted
                let count = min(30, max(1, Int(arguments["days"]?.number ?? 1)))
                do {
                    let days = try await Health.days(count, kinds: kinds)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "M月d日 EEE"
                    formatter.locale = Locale(identifier: "zh_CN")
                    var lines: [String] = []
                    // Newest first: if the text is cut short, what goes is the oldest days, not today.
                    for day in days.reversed() {
                        let parts = kinds.compactMap { kind in day.values[kind].map { "\(kind.title) \($0)" } }
                        lines.append(formatter.string(from: day.date) + "：" + (parts.isEmpty ? "没有记录" : parts.joined(separator: "；")))
                    }
                    let empty = days.allSatisfy { $0.values.isEmpty }
                    let note = empty ? "\n（一条记录都没有：可能用户在「设置 › 健康 › 数据访问」里没给 Clio 打开这些项目，iOS 不会告诉 app 是哪种情况。）" : ""
                    return ToolOutput(lines.joined(separator: "\n") + note)
                } catch {
                    return ToolOutput(Health.explain(error), isError: true)
                }
            },
        ]
    }
}

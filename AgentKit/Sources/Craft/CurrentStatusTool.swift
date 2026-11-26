import Foundation

/// Zero-approval read-only tool reporting accurate local time, timezone, logical day,
/// current workspace binding, and running background task count on demand.
public struct CurrentStatusSnapshot: Equatable, Sendable {
    public var localDateTime: String
    public var timeZoneIdentifier: String
    public var logicalDay: String
    public var workplaceSummary: String
    public var activeBackgroundTasks: Int

    public init(
        localDateTime: String,
        timeZoneIdentifier: String,
        logicalDay: String,
        workplaceSummary: String,
        activeBackgroundTasks: Int
    ) {
        self.localDateTime = localDateTime
        self.timeZoneIdentifier = timeZoneIdentifier
        self.logicalDay = logicalDay
        self.workplaceSummary = workplaceSummary
        self.activeBackgroundTasks = max(0, activeBackgroundTasks)
    }

    public func formattedSummary() -> String {
        [
            "当前时间：\(localDateTime)（\(timeZoneIdentifier)）",
            "逻辑日（04:00 换日）：\(logicalDay)",
            "工作地点：\(workplaceSummary)",
            "运行中后台任务：\(activeBackgroundTasks)",
        ].joined(separator: "\n")
    }

    public static func capture(
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        workplaceSummary: String,
        activeBackgroundTasks: Int
    ) -> CurrentStatusSnapshot {
        var localized = calendar
        localized.timeZone = timeZone
        let comps = localized.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let formattedTime = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0
        )
        let logical = LogicalDay.day(of: now, calendar: localized)
        return CurrentStatusSnapshot(
            localDateTime: formattedTime,
            timeZoneIdentifier: timeZone.identifier,
            logicalDay: logical,
            workplaceSummary: workplaceSummary,
            activeBackgroundTasks: activeBackgroundTasks
        )
    }
}

/// Zero-approval read-only status tool so models do not need a mutable timestamp in the stable prefix.
public struct CurrentStatusTool: AgentTool {
    public let provider: @Sendable () async -> CurrentStatusSnapshot
    public var isReadOnlySafe: Bool { true }

    public init(provider: @escaping @Sendable () async -> CurrentStatusSnapshot) {
        self.provider = provider
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "current_status",
            description: "查询当前精确的本地时间、时区、逻辑日、工作目录和运行中的后台任务数。不需要猜时间或询问用户几点了。",
            parameters: [
                "type": "object",
                "properties": [:],
            ]
        )
    }

    public func label(for arguments: JSONValue) -> String {
        "查看当前状态"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let snapshot = await provider()
        return ToolOutput(snapshot.formattedSummary())
    }
}

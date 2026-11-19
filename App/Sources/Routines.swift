import AgentKit
import Craft
import SwiftUI
import UserNotifications

// MARK: Tools

/// 定时 as the companions use it: set one up, see them, take one down.
enum RoutineTools {
    static func all(team: TeamModel, botId: String) -> [AgentTool] {
        [Schedule(team: team, botId: botId), Listing(team: team), Cancel(team: team)]
    }

    struct Schedule: AgentTool {
        let team: TeamModel
        let botId: String

        var spec: ToolSpec {
            ToolSpec(name: "schedule_task", description: "设一个定时任务：到了时间，你会重新收到这段指令并去做（比如每天早上整理新闻、每个工作日傍晚提醒写日报、每周日总结这周的账）。只提醒一次的用 message_later。到点时手机会弹通知，用户打开 Clio 就开始做。会先请用户批准。", parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "几个字的名字，比如：早间新闻"],
                    "prompt": ["type": "string", "description": "到时候你要做的事，写成给自己的完整指令"],
                    "time": ["type": "string", "description": "几点，24 小时制，比如 08:30"],
                    "days": ["type": "string", "description": "哪几天：每天、工作日、周末，或者 1,3,5（周一=1，周日=7）。不填就是每天"],
                ],
                "required": ["title", "prompt", "time"],
            ])
        }

        func label(for arguments: JSONValue) -> String { "定时：\(arguments["title"]?.string ?? "")" }

        func approval(for arguments: JSONValue) -> ApprovalAsk? {
            let days = Routine.days(from: arguments["days"]?.string)
            let clock = Routine.clock(arguments["time"]?.string)
            let routine = Routine(botId: botId, title: "", prompt: "", hour: clock?.hour ?? 0, minute: clock?.minute ?? 0, days: days)
            return ApprovalAsk(title: "新建定时任务", reason: "\(routine.when)  \(arguments["title"]?.string ?? "")", detail: arguments["prompt"]?.string)
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            let title = arguments["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = arguments["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !prompt.isEmpty else { return ToolOutput("要有名字和要做的事。", isError: true) }
            guard let clock = Routine.clock(arguments["time"]?.string) else { return ToolOutput("时间看不懂，写成 08:30 这样。", isError: true) }
            let routine = Routine(botId: botId, title: String(title.prefix(20)), prompt: prompt, hour: clock.hour, minute: clock.minute, days: Routine.days(from: arguments["days"]?.string))
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
            await MainActor.run { team.setRoutine(routine) }
            let next = routine.next(after: Date()).map { When.show($0) } ?? ""
            return ToolOutput("设好了：\(routine.when)「\(routine.title)」，下一次是 \(next)。" + (allowed ? "到点会弹通知，用户打开 Clio 就开始。" : "用户没开通知权限，到点不会提醒，只有打开 Clio 时才会做。"))
        }
    }

    struct Listing: AgentTool {
        let team: TeamModel

        var spec: ToolSpec {
            ToolSpec(name: "scheduled_tasks", description: "看已经设好的定时任务。", parameters: ["type": "object", "properties": [:]])
        }

        func label(for arguments: JSONValue) -> String { "看定时任务" }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            let lines = await MainActor.run {
                team.routines.map { routine in
                    let who = team.bots.first { $0.id == routine.botId }?.name ?? "?"
                    return "- [\(routine.id.prefix(6))] \(routine.when)「\(routine.title)」由\(who)做" + (routine.on ? "" : "（停着）") + "：\(routine.prompt.prefix(80))"
                }
            }
            return ToolOutput(lines.isEmpty ? "还没有定时任务。" : lines.joined(separator: "\n"))
        }
    }

    struct Cancel: AgentTool {
        let team: TeamModel

        var spec: ToolSpec {
            ToolSpec(name: "cancel_task", description: "删掉一个定时任务。给 scheduled_tasks 里方括号中的编号，或任务名字。会先请用户批准。", parameters: [
                "type": "object",
                "properties": ["task": ["type": "string", "description": "编号或名字"]],
                "required": ["task"],
            ])
        }

        func label(for arguments: JSONValue) -> String { "删定时任务：\(arguments["task"]?.string ?? "")" }

        func approval(for arguments: JSONValue) -> ApprovalAsk? {
            ApprovalAsk(title: "删掉定时任务", reason: arguments["task"]?.string ?? "")
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            let words = arguments["task"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let found: Routine? = await MainActor.run {
                team.routines.first { $0.id.hasPrefix(words) && words.count >= 4 } ?? team.routines.first { $0.title == words } ?? team.routines.first { $0.title.contains(words) && !words.isEmpty }
            }
            guard let found else { return ToolOutput("没找到「\(words)」这个定时任务。先用 scheduled_tasks 看看。", isError: true) }
            await MainActor.run { team.removeRoutine(found.id) }
            return ToolOutput("删掉了：\(found.when)「\(found.title)」。")
        }
    }
}

// MARK: Notifications

extension Notify {
    /// One repeating notification per day the routine runs on.
    static func schedule(_ routine: Routine, from name: String) {
        unschedule(routine: routine.id)
        guard routine.on else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "\(name)要做：\(routine.title)"
        content.body = "打开 Clio，\(name)就开始做。"
        content.sound = .default
        content.userInfo = ["chat": TeamModel.key(bot: routine.botId)]
        for day in routine.days.isEmpty ? [0] : routine.days {
            var parts = DateComponents()
            parts.hour = routine.hour
            parts.minute = routine.minute
            if day > 0 { parts.weekday = Routine.weekday(day) }
            center.add(UNNotificationRequest(identifier: "routine-\(routine.id)-\(day)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
        }
    }

    static func unschedule(routine id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0...7).map { "routine-\(id)-\($0)" })
    }
}

// MARK: Page

/// 定时: the routines, each with its time, who does it and what; on, off, change, take away.
struct RoutinesPage: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Routine?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    Text("到点弹通知，打开 Clio 就开始做")
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    if team.routines.isEmpty {
                        EmptyNote(symbol: "alarm", words: "还没有定时任务。点右上角的 ＋ 设一个。")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(team.routines) { routine in
                                row(routine)
                                Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, Ink.Space.l)
                            }
                        }
                        .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("定时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("好了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        guard let bot = team.mainBotId ?? team.bots.first?.id else { return }
                        editing = Routine(botId: bot, title: "", prompt: "", hour: 8, minute: 0)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建定时任务")
                    .disabled(team.bots.isEmpty)
                }
            }
        }
        .hitchPage("定时")
        .sheet(item: $editing) { routine in
            RoutineEditor(team: team, routine: routine)
        }
    }

    private func row(_ routine: Routine) -> some View {
        let who = team.bots.first { $0.id == routine.botId }?.name ?? "?"
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(routine.on ? Ink.ink : Ink.inkFaint)
                Text("\(routine.when) · \(who)").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                Text(routine.prompt).font(Ink.footnote).foregroundStyle(Ink.inkFaint).lineLimit(2)
                if let last = routine.lastRun {
                    Text("上次：\(When.show(Date(timeIntervalSince1970: last)))").font(.system(size: 11)).foregroundStyle(Ink.inkFaint)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { routine.on }, set: { value in
                var changed = routine
                changed.on = value
                if value { changed.lastRun = Date().timeIntervalSince1970 }
                team.setRoutine(changed)
            }))
            .labelsHidden()
            .tint(Ink.accent)
        }
        .padding(Ink.Space.l)
        .contentShape(Rectangle())
        .onTapGesture { editing = routine }
        .contextMenu {
            Button("改一改", systemImage: "pencil") { editing = routine }
            Button("删掉", systemImage: "trash", role: .destructive) { withAnimation(.smooth) { team.removeRoutine(routine.id) } }
        }
    }
}

/// Setting up or changing one routine.
struct RoutineEditor: View {
    @ObservedObject var team: TeamModel
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    @State private var time = Date()

    private static let names = ["一", "二", "三", "四", "五", "六", "日"]

    init(team: TeamModel, routine: Routine) {
        self.team = team
        _routine = State(initialValue: routine)
        _time = State(initialValue: Calendar.current.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: Date()) ?? Date())
    }

    private var isNew: Bool { !team.routines.contains { $0.id == routine.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section("叫什么") {
                    TextField("比如：早间新闻", text: $routine.title)
                }
                Section {
                    TextField("到点要做什么，比如：搜一下今天的科技新闻，挑 5 条最重要的，每条一句话。", text: $routine.prompt, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("要做的事")
                } footer: {
                    Text("到点时作为你的话发给旅伴")
                }
                Section("什么时候") {
                    DatePicker("几点", selection: $time, displayedComponents: .hourAndMinute)
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            let on = routine.days.isEmpty || routine.days.contains(day)
                            Button(Self.names[day - 1]) { toggle(day) }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(on ? Ink.paper : Ink.inkSoft)
                                .frame(width: 34, height: 34)
                                .background(on ? Ink.accent : Ink.mine, in: .circle)
                                .buttonStyle(.plain)
                        }
                    }
                    Text(preview.when).font(.footnote).foregroundStyle(.secondary)
                }
                Section("谁来做") {
                    Picker("旅伴", selection: $routine.botId) {
                        ForEach(team.bots) { bot in Text(bot.name).tag(bot.id) }
                    }
                }
                if !isNew {
                    Section {
                        Button("删掉这个定时任务", role: .destructive) {
                            team.removeRoutine(routine.id)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(isNew ? "新的定时任务" : "定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存好") { save() }
                        .disabled(routine.title.trimmingCharacters(in: .whitespaces).isEmpty || routine.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var preview: Routine {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        var shown = routine
        shown.hour = parts.hour ?? 8
        shown.minute = parts.minute ?? 0
        return shown
    }

    private func toggle(_ day: Int) {
        Haptics.tick(0.5)
        var days = routine.days.isEmpty ? Array(1...7) : routine.days
        if days.contains(day) { days.removeAll { $0 == day } } else { days.append(day) }
        days.sort()
        routine.days = days.count == 7 || days.isEmpty ? [] : days
    }

    private func save() {
        var kept = preview
        kept.title = kept.title.trimmingCharacters(in: .whitespacesAndNewlines)
        kept.prompt = kept.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // A routine set up or changed now starts counting from now: nothing earlier is owed.
        kept.lastRun = Date().timeIntervalSince1970
        team.setRoutine(kept)
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        Haptics.thud()
        dismiss()
    }
}

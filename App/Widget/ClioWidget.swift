import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The companion on the home screen: name, what it is doing, the last thing it said. A tap opens that conversation.
struct CompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct CompanionProvider: TimelineProvider {
    private let sample = WidgetSnapshot(name: "团子", status: "闲坐", line: "今天想聊点什么？", at: Date().timeIntervalSince1970, chat: "")

    func placeholder(in context: Context) -> CompanionEntry { CompanionEntry(date: Date(), snapshot: sample) }

    func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
        completion(CompanionEntry(date: Date(), snapshot: Shelf.take() ?? (context.isPreview ? sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
        let entry = CompanionEntry(date: Date(), snapshot: Shelf.take())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct CompanionWidgetView: View {
    /// Resting unless the app said it is working or waiting: the resting word itself differs between 日常 and 书卷.
    static func idle(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.status != "在干活" && snapshot.status != "等你批准"
    }

    let entry: CompanionEntry
    @Environment(\.widgetFamily) private var family

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.91)
    private let ink = Color(red: 0.16, green: 0.15, blue: 0.14)
    private let soft = Color(red: 0.42, green: 0.39, blue: 0.36)
    private let accent = Color(red: 0.27, green: 0.38, blue: 0.56)

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: (entry.snapshot.map(Self.idle) ?? true) ? "bubble.left" : "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
            }
            .widgetURL(URL(string: "clio://ask"))
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Text(entry.snapshot.map { "\($0.name) · \($0.status)" } ?? "Clio")
                .widgetURL(URL(string: "clio://ask"))
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.map { "\($0.name) · \($0.status)" } ?? "Clio").font(.system(size: 13, weight: .semibold))
                Text(entry.snapshot?.line.isEmpty == false ? entry.snapshot!.line : "点一下问点什么")
                    .font(.system(size: 13)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: entry.snapshot.map { "clio://chat/\($0.chat)" } ?? "clio://ask"))
            .containerBackground(.clear, for: .widget)
        default:
            home
        }
    }

    private var home: some View {
        Group {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        Text(snapshot.name).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Self.idle(snapshot) ? Color.green.opacity(0.7) : accent).frame(width: 6, height: 6)
                        Text(snapshot.status).font(.system(size: 12)).foregroundStyle(soft)
                    }
                    Text(snapshot.line.isEmpty ? "还没说话" : snapshot.line)
                        .font(.system(size: family == .systemSmall ? 13 : 14, design: .serif))
                        .foregroundStyle(ink)
                        .lineLimit(family == .systemSmall ? 3 : 4)
                    Spacer(minLength: 0)
                    if snapshot.at > 0 {
                        Text(Date(timeIntervalSince1970: snapshot.at), style: .relative).font(.system(size: 11)).foregroundStyle(soft)
                    }
                }
                .widgetURL(URL(string: "clio://chat/\(snapshot.chat)"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "bubble.left").foregroundStyle(accent)
                    Text("打开 Clio 一次，这里就会有旅伴的近况。").font(.system(size: 13, design: .serif)).foregroundStyle(soft)
                }
            }
        }
        .containerBackground(paper, for: .widget)
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "companion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("旅伴")
        .description("旅伴在做什么，最后说了一句什么。点一下回到那段絮语。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ClioWidgets: WidgetBundle {
    var body: some Widget {
        CompanionWidget()
        TurnActivityWidget()
        AskControl()
        DictateControl()
    }
}

/// Control Center, the lock screen and the Action Button: open Clio at the composer.
struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.lllhr94.clio.ask") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "clio://ask")!)) {
                Label("问 Clio", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .displayName("问 Clio")
        .description("打开 Clio，停在最近那段对话的输入框。")
    }
}

/// The same, listening right away.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.lllhr94.clio.dictate") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "clio://dictate")!)) {
                Label("对 Clio 说话", systemImage: "mic")
            }
        }
        .displayName("对 Clio 说话")
        .description("打开 Clio 就开始听写，说完你自己点发送。")
    }
}


/// The Live Activity: a companion's turn on the lock screen and in the Dynamic Island.
struct TurnActivityWidget: Widget {
    private static let paper = Color(red: 0.97, green: 0.95, blue: 0.91)
    private static let ink = Color(red: 0.16, green: 0.15, blue: 0.14)
    private static let soft = Color(red: 0.42, green: 0.39, blue: 0.36)
    private static let accent = Color(red: 0.43, green: 0.60, blue: 0.78)
    private static let warn = Color(red: 0.85, green: 0.65, blue: 0.36)
    private static let ok = Color(red: 0.50, green: 0.69, blue: 0.55)
    private static let stop = Color(red: 0.83, green: 0.47, blue: 0.44)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnAttributes.self) { context in
            LockScreenTurn(context: context)
                .activityBackgroundTint(Self.paper.opacity(0.92))
                .activitySystemActionForegroundColor(Self.ink)
                .widgetURL(URL(string: "clio://chat/\(context.attributes.chat)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.name, systemImage: "bubble.left")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Self.accent)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Self.clock(context.state)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(context.state.phase)).foregroundStyle(Self.tint(context.state.phase))
                        Text(context.state.doing).font(.system(size: 14)).lineLimit(2)
                        Spacer(minLength: 0)
                        if context.state.steps > 0 {
                            Text("\(context.state.steps) 步").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Self.face(context)
            } compactTrailing: {
                Self.mark(context.state)
            } minimal: {
                Self.face(context)
            }
            .widgetURL(URL(string: "clio://chat/\(context.attributes.chat)"))
            .keylineTint(Self.accent)
        }
    }

    /// The companion's tiny face (its pet in pixels, or its photo); a plain mark if none came along.
    @ViewBuilder
    static func face(_ context: ActivityViewContext<TurnAttributes>) -> some View {
        if let data = context.attributes.face, let picture = UIImage(data: data) {
            Image(uiImage: picture)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "bubble.left.fill").foregroundStyle(accent)
        }
    }

    /// Right of the island, kept small: a ring that keeps filling while it works, ✓ when done.
    @ViewBuilder
    static func mark(_ state: TurnAttributes.ContentState) -> some View {
        switch state.phase {
        case .working:
            let from = state.ring ?? state.started
            ProgressView(timerInterval: from...from.addingTimeInterval(60), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(accent)
            .frame(width: 20, height: 20)
        case .waiting:
            Image(systemName: "hand.raised.fill").foregroundStyle(warn)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ok)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(stop)
        }
    }

    static func symbol(_ phase: TurnAttributes.ContentState.Phase) -> String {
        switch phase {
        case .working: return "ellipsis.circle"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ phase: TurnAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .working: return accent
        case .waiting: return warn
        case .done: return ok
        case .failed: return stop
        }
    }

    static func word(_ phase: TurnAttributes.ContentState.Phase) -> String {
        switch phase {
        case .working: return "在做"
        case .waiting: return "等你"
        case .done: return "好了"
        case .failed: return "出错"
        }
    }

    /// Counts up while working; the time it took once done.
    @ViewBuilder
    static func clock(_ state: TurnAttributes.ContentState) -> some View {
        if let ended = state.ended {
            Text(Duration.seconds(max(0, ended.timeIntervalSince(state.started))).formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: state.started...Date.distantFuture, countsDown: false)
        }
    }

    struct LockScreenTurn: View {
        let context: ActivityViewContext<TurnAttributes>

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(TurnActivityWidget.tint(context.state.phase).opacity(0.18))
                    Image(systemName: TurnActivityWidget.symbol(context.state.phase))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TurnActivityWidget.tint(context.state.phase))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(context.attributes.name).font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(TurnActivityWidget.ink)
                        Text(TurnActivityWidget.word(context.state.phase)).font(.system(size: 12, weight: .medium)).foregroundStyle(TurnActivityWidget.tint(context.state.phase))
                        Spacer(minLength: 0)
                        TurnActivityWidget.clock(context.state).font(.system(size: 13).monospacedDigit()).foregroundStyle(TurnActivityWidget.soft).frame(maxWidth: 70, alignment: .trailing)
                    }
                    Text(context.state.doing).font(.system(size: 14, design: .serif)).foregroundStyle(TurnActivityWidget.ink).lineLimit(2)
                    if context.state.steps > 0 {
                        Text("用了 \(context.state.steps) 次工具").font(.system(size: 11)).foregroundStyle(TurnActivityWidget.soft)
                    }
                }
            }
            .padding(14)
        }
    }
}

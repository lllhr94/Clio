import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Light, dark and pure-black (OLED) pigments matching Clio's `Ink` palette inside the widget extension.
fileprivate struct WidgetPalette {
    let paper: Color
    let ink: Color
    let soft: Color
    let accent: Color
    let ok: Color
    let warn: Color
    let stop: Color

    static let light = WidgetPalette(
        paper: hex(0xF6F1E7),
        ink: hex(0x2B2A27),
        soft: hex(0x6F6A60),
        accent: hex(0x4F7099),
        ok: hex(0x4D7C5B),
        warn: hex(0xA9772F),
        stop: hex(0xB23A2B)
    )

    static func dark(oled: Bool) -> WidgetPalette {
        WidgetPalette(
            paper: hex(oled ? 0x000000 : 0x1C1A17),
            ink: hex(0xECE6DA),
            soft: hex(0xA39C8E),
            accent: hex(0x7DA2CC),
            ok: hex(0x7EB38B),
            warn: hex(0xD9A65C),
            stop: hex(0xD6746B)
        )
    }

    static func resolve(_ scheme: ColorScheme, oled: Bool) -> WidgetPalette {
        scheme == .dark ? dark(oled: oled) : light
    }

    static func activityBackground(oled: Bool) -> Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return uiHex(oled ? 0x000000 : 0x1C1A17, alpha: 0.95)
            }
            return uiHex(0xF6F1E7, alpha: 0.94)
        })
    }

    static let activityForeground = Color(UIColor { traits in
        uiHex(traits.userInterfaceStyle == .dark ? 0xECE6DA : 0x2B2A27, alpha: 1)
    })

    private static func hex(_ value: UInt32) -> Color {
        Color(uiHex(value, alpha: 1))
    }

    private static func uiHex(_ value: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The companion on the home screen: name, what it is doing, the last thing it said. A tap opens that conversation.
struct CompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct CompanionProvider: TimelineProvider {
    private let sample = WidgetSnapshot(
        name: "团子",
        status: "空闲",
        line: "今天想聊点什么？",
        at: Date().timeIntervalSince1970,
        chat: "",
        kind: .idle
    )

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
    static func kind(of snapshot: WidgetSnapshot) -> WidgetSnapshot.Kind {
        if let kind = snapshot.kind { return kind }
        if snapshot.status == "等你批准" || snapshot.status == "等你确认" || snapshot.status == "等你落款" { return .waiting }
        if snapshot.status == "在干活" || snapshot.status == "正在干活" { return .working }
        return .idle
    }

    static func chatURL(for snapshot: WidgetSnapshot?) -> URL? {
        guard let chat = snapshot?.chat, !chat.isEmpty else { return URL(string: "clio://ask") }
        return URL(string: "clio://chat/\(chat)")
    }

    let entry: CompanionEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var palette: WidgetPalette {
        WidgetPalette.resolve(scheme, oled: entry.snapshot?.oled == true)
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: circularSymbol)
                    .font(.system(size: 20, weight: .semibold))
            }
            .widgetURL(Self.chatURL(for: entry.snapshot))
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Text(entry.snapshot.map { "\($0.name) · \($0.status)" } ?? "Clio")
                .lineLimit(1)
                .widgetURL(Self.chatURL(for: entry.snapshot))
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot.map { "\($0.name) · \($0.status)" } ?? "Clio")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text(entry.snapshot?.line.isEmpty == false ? entry.snapshot!.line : "点一下问点什么")
                    .font(.system(size: 13))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Self.chatURL(for: entry.snapshot))
            .containerBackground(.clear, for: .widget)
        default:
            home
        }
    }

    private var circularSymbol: String {
        guard let snapshot = entry.snapshot else { return "bubble.left" }
        switch Self.kind(of: snapshot) {
        case .idle: return "bubble.left"
        case .working: return "ellipsis"
        case .waiting: return "hand.raised.fill"
        }
    }

    private func dotColor(for snapshot: WidgetSnapshot) -> Color {
        switch Self.kind(of: snapshot) {
        case .idle: return palette.ok
        case .working: return palette.accent
        case .waiting: return palette.warn
        }
    }

    private var home: some View {
        Group {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .widgetAccentable()
                        Text(snapshot.name)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(dotColor(for: snapshot))
                            .frame(width: 6, height: 6)
                        Text(snapshot.status)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.soft)
                            .lineLimit(1)
                    }
                    Text(snapshot.line.isEmpty ? "还没说话" : snapshot.line)
                        .font(.system(size: family == .systemSmall ? 13 : 14, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineLimit(family == .systemSmall ? 3 : 4)
                    Spacer(minLength: 0)
                    if snapshot.at > 0 {
                        Text(Date(timeIntervalSince1970: snapshot.at), style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.soft)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(Self.chatURL(for: snapshot))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .widgetAccentable()
                    Text("打开 Clio 一次，这里就会显示助手近况。")
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(palette.soft)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(URL(string: "clio://ask"))
            }
        }
        .containerBackground(palette.paper, for: .widget)
    }
}

struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "companion", provider: CompanionProvider()) { entry in
            CompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Clio 近况")
        .description("助手在做什么、最后说了什么。点一下回到那段对话。")
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
    private static let islandPalette = WidgetPalette.dark(oled: true)

    static func activityURL(for chat: String) -> URL? {
        chat.isEmpty ? URL(string: "clio://ask") : URL(string: "clio://chat/\(chat)")
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnAttributes.self) { context in
            LockScreenTurn(context: context)
                .activityBackgroundTint(WidgetPalette.activityBackground(oled: context.attributes.oled == true))
                .activitySystemActionForegroundColor(WidgetPalette.activityForeground)
                .widgetURL(Self.activityURL(for: context.attributes.chat))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Self.face(context, size: 20)
                        Text(context.attributes.name)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(Self.islandPalette.ink)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Self.clock(context.state)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Self.islandPalette.soft)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .frame(minWidth: 44, maxWidth: 68, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(context.state.phase))
                            .foregroundStyle(Self.tint(context.state.phase, palette: Self.islandPalette))
                        Text(context.state.doing)
                            .font(.system(size: 14))
                            .foregroundStyle(Self.islandPalette.ink)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if context.state.steps > 0 {
                            Text("\(context.state.steps) 步")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Self.islandPalette.soft)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
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
            .widgetURL(Self.activityURL(for: context.attributes.chat))
            .keylineTint(Self.islandPalette.accent)
        }
    }

    /// The companion's tiny face (its pet in pixels, or its photo); a plain mark if none came along.
    @ViewBuilder
    static func face(_ context: ActivityViewContext<TurnAttributes>, size: CGFloat = 24) -> some View {
        if let data = context.attributes.face, let picture = UIImage(data: data) {
            Image(uiImage: picture)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bubble.left.fill")
                .foregroundStyle(islandPalette.accent)
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
            .tint(islandPalette.accent)
            .frame(width: 20, height: 20)
        case .waiting:
            Image(systemName: "hand.raised.fill").foregroundStyle(islandPalette.warn)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(islandPalette.ok)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(islandPalette.stop)
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

    fileprivate static func tint(_ phase: TurnAttributes.ContentState.Phase, palette: WidgetPalette) -> Color {
        switch phase {
        case .working: return palette.accent
        case .waiting: return palette.warn
        case .done: return palette.ok
        case .failed: return palette.stop
        }
    }

    static func word(_ phase: TurnAttributes.ContentState.Phase) -> String {
        switch phase {
        case .working: return "在做"
        case .waiting: return "等你"
        case .done: return "完成"
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
        @Environment(\.colorScheme) private var scheme

        private var palette: WidgetPalette {
            WidgetPalette.resolve(scheme, oled: context.attributes.oled == true)
        }

        private var phaseColor: Color {
            TurnActivityWidget.tint(context.state.phase, palette: palette)
        }

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(phaseColor.opacity(0.18))
                    Image(systemName: TurnActivityWidget.symbol(context.state.phase))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(phaseColor)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(context.attributes.name)
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                        Text(TurnActivityWidget.word(context.state.phase))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(phaseColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        TurnActivityWidget.clock(context.state)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(palette.soft)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .frame(minWidth: 44, maxWidth: 72, alignment: .trailing)
                    }
                    Text(context.state.doing)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    if context.state.steps > 0 {
                        Text("用了 \(context.state.steps) 次工具")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.soft)
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
        }
    }
}

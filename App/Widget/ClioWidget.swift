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
    let entry: CompanionEntry
    @Environment(\.widgetFamily) private var family

    private let paper = Color(red: 0.97, green: 0.95, blue: 0.91)
    private let ink = Color(red: 0.16, green: 0.15, blue: 0.14)
    private let soft = Color(red: 0.42, green: 0.39, blue: 0.36)
    private let accent = Color(red: 0.27, green: 0.38, blue: 0.56)

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "water.waves").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        Text(snapshot.name).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(snapshot.status == "闲坐" ? Color.green.opacity(0.7) : accent).frame(width: 6, height: 6)
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
                    Image(systemName: "water.waves").foregroundStyle(accent)
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClioWidgets: WidgetBundle {
    var body: some Widget {
        CompanionWidget()
    }
}

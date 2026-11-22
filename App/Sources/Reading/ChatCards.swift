import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 问答目录: the conversation as a list of what you asked and how each answer began; search it, tap to go there.
/// After Kelivo's mini map (only the idea).
struct OutlineSheet: View {
    struct Pair: Identifiable {
        let id: String
        let question: String
        let answer: String?
        let at: Double?
    }

    let pairs: [Pair]
    let go: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [Pair] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return pairs }
        return pairs.filter { $0.question.localizedCaseInsensitiveContains(wanted) || ($0.answer?.localizedCaseInsensitiveContains(wanted) ?? false) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, pair in
                    Button {
                        Haptics.light()
                        go(pair.id)
                    } label: {
                        HStack(alignment: .top, spacing: Ink.Space.m) {
                            Text("\(index + 1)")
                                .font(Ink.footnote.monospacedDigit())
                                .foregroundStyle(Ink.inkFaint)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                                Text(pair.question)
                                    .font(.system(size: Ink.Size.sub, weight: .medium))
                                    .foregroundStyle(Ink.ink)
                                    .lineLimit(2)
                                if let answer = pair.answer, !answer.isEmpty {
                                    Text(answer)
                                        .font(.system(size: Ink.Size.small))
                                        .foregroundStyle(Ink.inkSoft)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.vertical, Ink.Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Ink.paperRaised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .overlay {
                if shown.isEmpty {
                    Text(pairs.isEmpty ? "还没有问答" : "没找到")
                        .font(Ink.footnote)
                        .foregroundStyle(Ink.inkFaint)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "找问过的话")
            .navigationTitle(L.t("chat.outline"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
            }
        }
    }
}

/// What 健康 said, as a small card: a row per day, each number with its name under it.
struct HealthCard: View {
    let text: String
    let format: String?

    private struct Day: Identifiable {
        let id: Int
        let date: String
        let values: [(name: String, value: String)]
    }

    private var days: [Day] {
        HealthCardRows.newest(text, format: format).enumerated().compactMap { index, row in
            let parts = row.split(separator: "：", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let values = parts[1].split(separator: "；").compactMap { item -> (String, String)? in
                let piece = item.trimmingCharacters(in: .whitespaces)
                guard let space = piece.firstIndex(of: " ") else { return nil }
                return (String(piece[..<space]), String(piece[piece.index(after: space)...]))
            }
            return Day(id: index, date: parts[0], values: values)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Label("健康", systemImage: "heart.text.square")
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.Tile.yan)
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(day.date).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                    if day.values.isEmpty {
                        Text("没有记录").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    } else {
                        HStack(alignment: .top, spacing: Ink.Space.l) {
                            ForEach(Array(day.values.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.value).font(Ink.mono(Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1).minimumScaleFactor(0.7)
                                    Text(item.name).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkSoft)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Ink.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
        .accessibilityElement(children: .combine)
    }
}

/// 回望: what the steps changed in the companion's mind, in the 心绪 colour, one line, opened by a tap.
struct LookbackLine: View {
    let text: String
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tick(0.4)
            withAnimation(Ink.Motion.settle) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: Ink.Size.micro, weight: .semibold))
                Text("回望 · " + text)
                    .font(Ink.footnote)
                    .lineLimit(open ? nil : 1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.accent.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回望：" + text)
    }
}

/// The weather tool's answer as a card: the place and now on top, then a row a day with a small sky and the range.
struct WeatherCard: View {
    let text: String

    private struct Day: Identifiable {
        let id: Int
        let date: String
        let sky: String
        let range: String
        let rain: String
    }

    private var lines: [String] { text.split(separator: "\n").map(String.init) }
    private var place: String { lines.first ?? "" }
    private var now: String? { lines.first { $0.hasPrefix("现在：") }.map { String($0.dropFirst(3)) } }

    /// 「查询于：2026-11-21 14:00（Asia/Shanghai）」: when the forecast was fetched, in the place's own time.
    private var asked: (day: String, time: String, zone: TimeZone?)? {
        guard let line = lines.first(where: { $0.hasPrefix("查询于：") }) else { return nil }
        let body = line.dropFirst(4)
        let stamp = body.split(separator: "（").first.map(String.init) ?? ""
        let parts = stamp.split(separator: " ").map(String.init)
        guard let day = parts.first else { return nil }
        let zone = body.split(separator: "（").dropFirst().first.map { TimeZone(identifier: String($0.dropLast())) } ?? nil
        return (day, parts.count > 1 ? parts[1] : "", zone)
    }

    /// The place's date right now.
    private func today(in zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Fetched today, there: the card is live and may say 「今天」「明天」.
    private var live: Bool {
        guard let asked else { return false }
        return asked.day == today(in: asked.zone)
    }

    /// The line under the place for a card that is not today's: when it was looked up.
    private var fetchedNote: String? {
        guard !live else { return nil }
        guard let asked else { return "以前查的预报" }
        return "\(Self.shortDate(asked.day) ?? asked.day) \(asked.time) 查的"
    }

    private var days: [Day] {
        let isLive = self.live
        return lines.filter { $0.contains(" | ") && !$0.hasPrefix("日期") }.enumerated().compactMap { index, row in
            let cells = row.components(separatedBy: " | ")
            guard cells.count >= 4 else { return nil }
            return Day(id: index, date: Self.day(cells[0], index: index, live: isLive), sky: cells[1], range: cells[2], rain: cells[3])
        }
    }

    private static func parse(_ text: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: text)
    }

    private static func shortDate(_ text: String) -> String? {
        guard let date = parse(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// 「2026-11-22」 → 「今天」「明天」 on a live card, else 「周日」 or, on an old card, 「11/22」.
    private static func day(_ text: String, index: Int, live: Bool) -> String {
        if live, index == 0 { return "今天" }
        if live, index == 1 { return "明天" }
        guard let date = parse(text) else { return text }
        if !live { return shortDate(text) ?? text }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    static func symbol(_ sky: String) -> String {
        if sky.contains("雷") { return "cloud.bolt.rain" }
        if sky.contains("雪") { return "cloud.snow" }
        if sky.contains("雨") { return "cloud.rain" }
        if sky.contains("雾") { return "cloud.fog" }
        if sky.contains("阴") { return "cloud" }
        if sky.contains("多云") { return "cloud.sun" }
        if sky.contains("晴") { return "sun.max" }
        return "cloud.sun"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                Label(place, systemImage: "cloud.sun")
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let fetchedNote {
                    Text(fetchedNote).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                }
            }
            if let now {
                Text(live ? now : "当时：" + now)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(days) { day in
                HStack(spacing: Ink.Space.m) {
                    Text(day.date).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).frame(width: 44, alignment: .leading)
                    Image(systemName: Self.symbol(day.sky)).symbolRenderingMode(.multicolor).font(.system(size: Ink.Size.sub)).frame(width: 22)
                    Text(day.sky).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(1)
                    Spacer(minLength: Ink.Space.s)
                    if day.rain != "—", day.rain != "0%" {
                        Text(day.rain).font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.Tile.dai)
                    }
                    Text(day.range).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.ink).monospacedDigit()
                }
            }
        }
        .padding(Ink.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkBlock()
        .accessibilityElement(children: .combine)
    }
}

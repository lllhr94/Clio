import AgentKit
import Craft
import SwiftUI
import UIKit

// MARK: 潮水

/// The tide's finds on this phone: what waits on the sand, and the collection. Nothing here costs tokens.
@MainActor
final class TideBook: ObservableObject {
    static let shared = TideBook()

    /// On the sand, oldest first, a week at most.
    @Published private(set) var waiting: [Tide.Find] = []
    /// The collection, newest first.
    @Published private(set) var collected: [Tide.Find] = []

    private let defaults = UserDefaults.standard
    /// One per install, so two phones do not find the same things.
    private var seed: String {
        if let kept = defaults.string(forKey: "tide.seed") { return kept }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: "tide.seed")
        return fresh
    }

    private init() {
        if let data = defaults.data(forKey: "tide.collected"), let kept = try? JSONDecoder().decode([Tide.Find].self, from: data) { collected = kept }
        if let data = defaults.data(forKey: "tide.waiting"), let kept = try? JSONDecoder().decode([Tide.Find].self, from: data) { waiting = kept }
        refresh()
    }

    /// Lets in whatever the tide brought since the last look. Days long gone go straight into the collection.
    func refresh() {
        let today = Tide.day(of: Date())
        let last = defaults.string(forKey: "tide.last")
        guard last != today else { return }
        let arrivals = Tide.arrivals(after: last, through: today, seed: seed)
        var sand = waiting + arrivals.waiting
        let overflow = max(0, sand.count - 7)
        // More than a week on the sand: the oldest are put away for you, never lost.
        let putAway = Array(sand.prefix(overflow)) + arrivals.putAway
        sand.removeFirst(overflow)
        waiting = sand
        collected = (collected + putAway).sorted { $0.day > $1.day }
        defaults.set(today, forKey: "tide.last")
        save()
    }

    func pick(_ find: Tide.Find) {
        guard let index = waiting.firstIndex(of: find) else { return }
        var picked = waiting.remove(at: index)
        picked.picked = true
        collected.insert(picked, at: 0)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collected) { defaults.set(data, forKey: "tide.collected") }
        if let data = try? JSONEncoder().encode(waiting) { defaults.set(data, forKey: "tide.waiting") }
    }
}

/// On the desk: what the tide brought today, or the way to the collection. Costs nothing.
struct TideChip: View {
    @ObservedObject var book = TideBook.shared
    var keeper: String
    @State private var open = false

    var body: some View {
        Group {
            if let newest = book.waiting.last {
                Button {
                    Haptics.light()
                    open = true
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        Image(systemName: newest.symbol).font(.system(size: Ink.Size.title)).foregroundStyle(Ink.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.waiting.count > 1 ? "漂来了 \(book.waiting.count) 样东西" : "今天漂来了一样东西")
                                .font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink)
                            Text("点开，\(keeper)去捡起来").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                        }
                        Spacer(minLength: 0)
                        Kit.chevron
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                    .paperCard()
                }
                .buttonStyle(PressStyle())
                .padding(.bottom, Ink.Space.m)
            } else if !book.collected.isEmpty {
                Button {
                    Haptics.light()
                    open = true
                } label: {
                    Label("收藏册 · \(book.collected.count) 样", systemImage: "water.waves")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)
                        .frame(minHeight: 32)
                }
                .buttonStyle(TapStyle())
            }
        }
        .sheet(isPresented: $open) {
            TideSheet(keeper: keeper)
                .presentationDetents([.medium, .large])
        }
    }
}

/// The tide's corner of the desk: what it brought, picked up with a word from the whale; and the collection.
struct TideSheet: View {
    @ObservedObject var book = TideBook.shared
    /// Who picks things up: the main companion's name.
    var keeper: String
    @Environment(\.dismiss) private var dismiss
    @State private var shown: Tide.Find?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if let shown {
                        reveal(shown)
                    } else if !book.waiting.isEmpty {
                        Text("水上漂来的，点一下，\(keeper)去捡起来。")
                            .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Ink.Space.m)], spacing: Ink.Space.m) {
                            ForEach(book.waiting) { find in
                                Button {
                                    Haptics.tick(0.7)
                                    withAnimation(Ink.Motion.unfold) {
                                        book.pick(find)
                                        shown = find
                                    }
                                } label: {
                                    VStack(spacing: Ink.Space.s) {
                                        Image(systemName: find.symbol).font(.system(size: 26)).foregroundStyle(Ink.accent)
                                        Text(Self.when(find.day)).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 88)
                                    .paperCard()
                                }
                                .buttonStyle(PressStyle())
                                .accessibilityLabel("\(Self.when(find.day))漂来的东西，点一下捡起来")
                            }
                        }
                    }
                    Text("收藏册").font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft).padding(.top, Ink.Space.m)
                    if book.collected.isEmpty {
                        EmptyNote(symbol: "water.waves", words: L.t("empty.favorites"))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(book.collected) { find in
                                HStack(alignment: .top, spacing: Ink.Space.m) {
                                    Image(systemName: find.symbol).font(.system(size: Ink.Size.title)).foregroundStyle(Ink.accent).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(find.name).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                                        Text(find.line).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                        Text(Self.when(find.day) + (find.picked ? "" : Words.t(" · 潮水留下的"))).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Ink.Space.l)
                                .padding(.vertical, Ink.Space.m)
                                if find.id != book.collected.last?.id { Kit.rule(inset: 56) }
                            }
                        }
                        .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(Words.t("潮水"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .hitchPage("潮水")
    }

    private func reveal(_ find: Tide.Find) -> some View {
        VStack(spacing: Ink.Space.m) {
            Whale(size: 64, pose: .cheering)
            Image(systemName: find.symbol)
                .font(.system(size: 40))
                .foregroundStyle(Ink.accent)
                .transition(.scale.combined(with: .opacity))
            Text(find.name).font(Ink.serif(20, bold: true)).foregroundStyle(Ink.ink)
            Text("\(keeper)：\(find.line)").font(Ink.reading).foregroundStyle(Ink.inkSoft).multilineTextAlignment(.center)
            Button(book.waiting.isEmpty ? "收好了" : "再看看别的") {
                withAnimation(Ink.Motion.settle) { shown = nil }
            }
            .font(.system(size: Ink.Size.sub, weight: .medium))
            .foregroundStyle(Ink.accent)
            .buttonStyle(TapStyle())
            .padding(.top, Ink.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(Ink.Space.xl)
        .paperCard()
    }

    static func when(_ day: String) -> String {
        if day == Tide.day(of: Date()) { return "今天" }
        if day == Tide.day(of: Date().addingTimeInterval(-86_400)) { return "昨天" }
        let parts = day.split(separator: "-")
        return parts.count == 3 ? "\(Int(parts[1]) ?? 0) 月 \(Int(parts[2]) ?? 0) 日" : day
    }
}

/// A designed empty state: one picture, one sentence, at most one button.
struct EmptyNote: View {
    var symbol: String
    var words: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Ink.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Ink.inkFaint)
            Text(words)
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .buttonStyle(TapStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ink.Space.xl)
        .padding(.horizontal, Ink.Space.l)
    }
}

// MARK: 你不在时

/// Something that happened in a conversation: told in another one when you come back to it.
struct Happening: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case done, failed, waiting }
    var id = UUID().uuidString
    var chat: String
    var kind: Kind
    /// Milliseconds.
    var at: Double
}

// MARK: 日记

/// One evening's page in a companion's diary, and the line the user wrote back.
struct DiaryPage: Codable, Equatable, Identifiable {
    var day: String
    var text: String
    var reply: String?
    var id: String { day }
}

/// A companion's diary: written in the evening, kept on this phone, answered if you like.
struct DiarySheet: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [DiaryPage] = []
    @State private var drafts: [String: String] = [:]
    @State private var writing = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if pages.isEmpty {
                        EmptyNote(
                            symbol: "book.closed",
                            words: Pref.diaryOn ? "\(bot.name)还没写过日记。晚上九点以后，当天聊过的话会写成一页。" : Words.t("日记还没打开。在调弦 › 旅伴的日常里打开，\(bot.name)会在晚上写一页当天的日记。"),
                            action: ("现在写今天的", { write() })
                        )
                    }
                    if writing { ProgressView("正在写…").frame(maxWidth: .infinity) }
                    if let note { Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
                    ForEach(pages) { page in
                        VStack(alignment: .leading, spacing: Ink.Space.m) {
                            Text(TideSheet.when(page.day)).font(Ink.serif(15, bold: true)).foregroundStyle(Ink.inkSoft)
                            Text(page.text).font(Ink.reading).foregroundStyle(Ink.ink).lineSpacing(6)
                            if let reply = page.reply {
                                Text("你回：\(reply)").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            } else {
                                HStack(spacing: Ink.Space.s) {
                                    TextField("回\(bot.name)一句…", text: Binding(get: { drafts[page.day] ?? "" }, set: { drafts[page.day] = $0 }))
                                        .font(Ink.label)
                                    Button("回") {
                                        let words = (drafts[page.day] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !words.isEmpty else { return }
                                        team.replyDiary(bot.id, day: page.day, words)
                                        pages = team.diary(bot.id)
                                        Haptics.tick(0.6)
                                    }
                                    .disabled((drafts[page.day] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                    .buttonStyle(TapStyle())
                                }
                                .padding(.top, Ink.Space.xs)
                            }
                        }
                        .padding(Ink.Space.l)
                        .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("\(bot.name)的" + L.t("nav.diary"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !pages.isEmpty { Button("写今天的") { write() }.disabled(writing) }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } }
            }
        }
        .hitchPage("日记")
        .task { pages = team.diary(bot.id) }
    }

    private func write() {
        writing = true
        note = nil
        Task {
            do {
                try await team.writeDiary(bot.id)
                pages = team.diary(bot.id)
            } catch {
                note = error.localizedDescription
            }
            writing = false
        }
    }
}

extension TeamModel {
    // MARK: 你不在时

    private static let happeningsKey = "daily.happenings"
    private static let seenKey = "daily.seen"

    var happenings: [Happening] {
        guard let data = UserDefaults.standard.data(forKey: Self.happeningsKey) else { return [] }
        return (try? JSONDecoder().decode([Happening].self, from: data)) ?? []
    }

    func record(_ kind: Happening.Kind, in chat: String) {
        var list = happenings.filter { !($0.chat == chat && $0.kind == kind) }
        list.append(Happening(chat: chat, kind: kind, at: Now.ms))
        if let data = try? JSONEncoder().encode(Array(list.suffix(40))) { UserDefaults.standard.set(data, forKey: Self.happeningsKey) }
    }

    /// The user left this conversation now.
    /// Something new came in after the user last left this conversation.
    func isUnread(_ chat: String, at: Double) -> Bool {
        let seen = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double])?[chat] ?? 0
        return seen > 0 && at > seen + 1000
    }

    func markSeen(_ chat: String) {
        var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
        seen[chat] = Now.ms
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }

    /// What happened in the other conversations since the user was last here, newest first, one line per conversation.
    /// Nothing when they were here only a moment ago.
    func whileAway(from chat: String) -> [Happening] {
        let seen = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double])?[chat] ?? 0
        guard Now.ms - seen > 10 * 60 * 1000 else { return [] }
        var lines: [Happening] = []
        for happening in happenings.reversed() where happening.chat != chat && happening.at > seen {
            if !lines.contains(where: { $0.chat == happening.chat }) { lines.append(happening) }
        }
        for approval in approvals {
            guard let other = approval.chat, other != chat, !lines.contains(where: { $0.chat == other && $0.kind == .waiting }) else { continue }
            lines.removeAll { $0.chat == other }
            lines.insert(Happening(chat: other, kind: .waiting, at: approval.at ?? Now.ms), at: 0)
        }
        return Array(lines.prefix(4))
    }

    // MARK: 日记

    private static func diaryFile(_ bot: String) -> String { "diary/\(bot).json" }

    func diary(_ bot: String) -> [DiaryPage] {
        Disk.load([DiaryPage].self, Self.diaryFile(bot)) ?? []
    }

    func replyDiary(_ bot: String, day: String, _ words: String) {
        var pages = diary(bot)
        guard let index = pages.firstIndex(where: { $0.day == day }) else { return }
        pages[index].reply = words
        Disk.save(pages, Self.diaryFile(bot))
    }

    /// The last page and its answer, for the companion to remember (not to bring up unasked).
    func diaryLine(_ bot: String) -> String? {
        guard let page = diary(bot).first, page.day >= Tide.day(of: Date().addingTimeInterval(-2 * 86_400)) else { return nil }
        var line = "你最近一篇日记（\(TideSheet.when(page.day))）：\(page.text)"
        if let reply = page.reply { line += "\n用户在下面回了你：\(reply)" }
        return line + "\n（这是你们之间的小事：聊到相关的再提，不必主动说起。）"
    }

    /// Writes today's page for one companion from today's conversation with it. Throws when there is nothing to write about.
    func writeDiary(_ botId: String) async throws {
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let key = Self.key(bot: botId)
        let today = Tide.day(of: Date())
        let said = history(key).filter {
            $0.note != true && $0.message.role != .tool && !$0.message.text.isEmpty && Tide.day(of: Date(timeIntervalSince1970: $0.at / 1000)) == today
        }
        guard said.contains(where: { $0.message.role == .user }) else { throw TeamError(message: "今天还没和\(bot.name)聊过，没什么可写的。") }
        var transcript = said.map { ($0.message.role == .user ? "用户：" : "\(bot.name)：") + String($0.message.text.prefix(500)) }.joined(separator: "\n")
        if transcript.count > 6000 { transcript = String(transcript.suffix(6000)) }
        let persona = bot.instructions.map { "你的设定：\($0)\n" } ?? ""
        let system = "你是「\(bot.name)」，用户手机里的旅伴。\(persona)现在是晚上，用你自己的口吻写今天的日记：三到五句，写今天和用户聊了什么、你注意到的事、你的心情。像写给自己看的，温和、具体，不说教。不要标题、日期、列表和表情。"
        guard var agent = helper(for: key, system: system) else { throw TeamError(message: "还没有能用的模型。") }
        agent.outputLimit = 600
        let text = try await agent.ask("今天的对话：\n\n" + transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TeamError(message: "这次没写出来，过会儿再试。") }
        var pages = diary(botId).filter { $0.day != today }
        pages.insert(DiaryPage(day: today, text: text), at: 0)
        Disk.save(Array(pages.prefix(365)), Self.diaryFile(botId))
    }

    /// In the evening, the companions the user talked with today each write a page, once a day. Only when the user turned it on.
    func diaryIfDue() {
        guard Pref.diaryOn, phase == .ready, Calendar.current.component(.hour, from: Date()) >= 21 else { return }
        let today = Tide.day(of: Date())
        guard UserDefaults.standard.string(forKey: "diary.last") != today else { return }
        UserDefaults.standard.set(today, forKey: "diary.last")
        let grace = UIApplication.shared.beginBackgroundTask(withName: "clio-diary")
        Task { [weak self] in
            guard let self else { return }
            for bot in self.bots {
                let chattedToday = bot.lastAt.map { Tide.day(of: Date(timeIntervalSince1970: $0 / 1000)) == today } ?? false
                if chattedToday { try? await self.writeDiary(bot.id) }
            }
            if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) }
        }
    }
}

import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Compressing


    static func summaryFile(_ key: String) -> String { "chats/\(key)~summary.json" }

    /// The digest of the part of this conversation that was folded away.
    func summary(_ key: String) -> String? {
        if let kept = summaryBook[key] { return kept.isEmpty ? nil : kept }
        let loaded = keeping ? (Disk.load(String.self, Self.summaryFile(key)) ?? "") : ""
        summaryBook[key] = loaded
        return loaded.isEmpty ? nil : loaded
    }

    func setSummary(_ key: String, _ text: String?) {
        objectWillChange.send()
        summaryBook[key] = text ?? ""
        guard keeping else { return }
        if let text, !text.isEmpty { Disk.save(text, Self.summaryFile(key)) } else { Disk.remove(Self.summaryFile(key)) }
    }

    /// In-memory summary length for reactive triggers without touching disk on the main thread.
    func cachedSummaryLength(_ key: String) -> Int {
        summaryBook[key]?.count ?? 0
    }

    func summaryBlock(_ key: String) -> String {
        guard let summary = summary(key) else { return "" }
        return "\n\n这段絮语较早的部分已经压缩，下面是前情提要（原文还在对话里，用户能往上翻到）：\n" + summary
    }

    /// How long the conversation is, in characters.
    func size(of key: String) -> Int { Turns.size(Array(live(key))) }

    /// The part of the chat the model reads word for word: after the newest compression line. Everything before it
    /// stays in the conversation for you to scroll back to; the model has it as the 前情提要.
    func live(_ key: String) -> ArraySlice<Entry> {
        let all = history(key)
        let start = all.lastIndex(where: { $0.fold == true }).map { $0 + 1 } ?? 0
        return all[start...]
    }

    /// When to tidy up: before the model's window starts dropping the oldest lines, so nothing slips out unsummarised.
    func foldAt(_ key: String) -> Int {
        let total = window(of: key)
        return min(Int(Double(total) * Pref.compressShare), Self.budget(window: total, share: Pref.contextShare) * 9 / 10)
    }

    /// The window of the model this chat talks to, in tokens.
    func window(of key: String) -> Int {
        speaker(of: key)?.found.map { $0.endpoint.traits($0.model).window } ?? Tokens.window(for: "")
    }

    /// The default model's window, for the settings page to say what each share comes to.
    var defaultWindow: Int {
        resolve(settings.defaultModel).map { $0.endpoint.traits($0.model).window } ?? Tokens.window(for: "")
    }

    /// How much of the chat goes with a request, counted in characters (a character is about a token or less, so
    /// it errs short): the share of the window the user picked, always leaving room for the instructions, the tools
    /// and the reply, so a full window never leaves the model nothing to answer with.
    static func budget(window: Int, share: Double) -> Int {
        let reply = Pref.maxOutput > 0 ? max(Pref.maxOutput, 8_192) : 16_384
        let room = window - reply - 16_000
        return max(8_000, min(Int(Double(window) * share), room))
    }

    /// Compresses quietly, never in the way: it waits for nothing, and a turn goes on meanwhile with the chat as it is.
    func foldQuietly(_ key: String) {
        guard Pref.autoCompress, !compressing.contains(key), size(of: key) > foldAt(key) else { return }
        Task { [weak self] in _ = try? await self?.compress(key) }
    }

    static func foldSummary(_ key: String, _ marker: String) -> String { "chats/\(key)~fold-\(marker)~summary.json" }

    /// Folds the older part of a conversation into a digest. The full text is kept as a leaf. Returns how many messages were folded.
    @discardableResult
    func compress(_ key: String) async throws -> Int {
        guard !compressing.contains(key) else { return 0 }
        let all = Array(live(key))
        let firstCut: Int
        switch Turns.foldCut(all, keep: Pref.keepRecent) {
        case .success(let found): firstCut = found
        case .failure(let problem): throw TeamError(message: problem.words)
        }

        let speakerBot: BotInfo? = {
            if let bot = bots.first(where: { Self.key(bot: $0.id) == key }) { return bot }
            if let room = rooms.first(where: { Self.key(room: $0.id) == key }) { return bots.first { $0.id == room.members?.first } }
            return nil
        }()
        guard let bot = speakerBot, let found = resolve(bot.model ?? settings.defaultModel) ?? resolve(settings.defaultModel),
              let apiKey = apiKey(for: found.endpoint.id), !apiKey.isEmpty else {
            throw TeamError(message: "没有能用的模型来写前情提要。")
        }
        compressing.insert(key)
        defer { compressing.remove(key) }

        let crew = bots
        let speaker = { (entry: Entry) in entry.speaker.flatMap { id in crew.first { $0.id == id }?.name } ?? bot.name }
        // Only what the model will read is marked as folded: a part too long moves the cut earlier.
        let cut = Turns.fitCut(all, cut: firstCut, name: speaker, label: \.label)
        let (transcript, folded) = Turns.transcript(all[..<cut], name: speaker, label: \.label)
        let earlier = summary(key).map { "更早之前的前情提要：\n\($0)\n\n" } ?? ""
        let prompt = """
        \(earlier)下面是用户和「\(bot.name)」之前的对话。请写一份前情提要，供之后接着聊时参考。
        要保留：用户说过的关于自己的事、偏好、做过的决定、约定和待办、没解决的问题、重要的数字、名字、地址和链接。
        要略去：寒暄、反复的过程、已经过时的内容。
        用条目写，第三人称，900 字以内，只输出提要本身。

        \(transcript)
        """
        let agent = Agent(provider: found.endpoint.provider(key: apiKey), model: found.model, system: "你擅长把长对话整理成准确、简洁的提要。")
        let digest = try await agent.ask(prompt)
        guard !digest.isEmpty else { throw TeamError(message: "模型没给出提要。") }

        // Nothing is taken away: a line goes in before the first message kept word for word. The chat may have
        // moved on while the summary was written; a turn still running is left to finish first.
        let firstKept = all[cut].id
        while runs[key] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        var current = history(key)
        guard let at = current.firstIndex(where: { $0.id == firstKept }) else {
            throw TeamError(message: "整理的时候聊天变了，下次再整理。")
        }
        let markerId = UUID().uuidString
        if keeping, let old = summary(key) { Disk.save(old, Self.foldSummary(key, markerId)) }
        let marker = Entry(id: markerId, at: current[at].at - 1,
                           message: .assistant("以上较早的 \(folded) 条已整理成前情提要，原文都还在"), note: true, fold: true)
        current.insert(marker, at: at)
        entries[key] = current
        if keeping { ChatDisk.save(current, chat: key) }
        setSummary(key, digest)
        notify(key, .changed)
        return folded
    }
}

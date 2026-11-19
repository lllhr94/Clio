import AgentKit
import Craft
import SwiftUI

/// One step of a trace, opened up.
struct StepDetail: Equatable {
    var input: String
    var output: String
    var seconds: Int?
    /// A picture the step brought back, such as a page's screenshot (a kept photo's name).
    var photo: String?
    /// For the person only: a changed file's whole comparison.
    var full: String?
}

/// One row of a chat.
struct ChatLine: Identifiable, Equatable {
    enum Kind { case user, bot, steps, note }
    enum Local { case sending, failed }

    var id: String
    var kind: Kind
    var text: String
    /// A steps row that is still running.
    var live = false
    var local: Local?
    /// In a group: the Bot that said it.
    var speaker: String?
    var speakerName: String?
    /// Photos picked on this phone and not kept yet.
    var images: [Data] = []
    /// How many photos the message carries, and their files.
    var photos = 0
    var refs: [String] = []
    /// A steps row: what was done, in order.
    var tools: [String] = []
    /// A steps row: for each step, what went in, what came out, and how long it took.
    var details: [StepDetail] = []
    /// A steps row: how long its steps took; a reply: how long the turn took, in seconds.
    var seconds: Int?
    /// A reply: the tokens its turn used.
    var tokens: Int?
    /// A reply: what the model thought on the way to it, in this turn.
    var reasoning: String?
    /// A reply: the companion's 心绪 before it spoke.
    var pulse: String?
    /// A note about a failure: what to do next.
    var next: Explain.Next?
}

/// The chat with one Bot or one group: shows it, keeps it live, sends into it.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var lines: [ChatLine] = []
    @Published private(set) var pending: [ChatLine] = []
    /// The part of the reply being written that is on screen so far.
    @Published private(set) var streaming = ""
    /// What the model is thinking right now, before it answers or between steps. Cleared once it moves on.
    @Published private(set) var thinking = ""
    /// The 心绪 being written before the reply in progress.
    @Published private(set) var pulse = ""
    /// The reply that just finished: the row that took over from the streaming one.
    @Published private(set) var fresh: Fresh?

    struct Fresh: Equatable {
        var id: String
        /// How many characters are out so far; nil once the whole reply is.
        var shown: Int?
    }
    @Published private(set) var loaded = false
    @Published private(set) var demoWorking = false
    @Published var error: String?

    @Published private(set) var earlier: [ChatLine] = []
    @Published private(set) var hasEarlier = false
    @Published private(set) var loadingEarlier = false

    /// The Bot this chat is with. For a group: a stand-in that carries the group's name.
    let bot: BotInfo
    /// Set when this is a group chat.
    let roomId: String?
    /// Where the team keeps this chat.
    let key: String
    var sessionId: String { key }

    private let team: TeamModel
    private var feed: UUID?
    private var demoReply: Task<Void, Never>?
    /// How many kept messages are on screen.
    private var limit = 160
    /// The tool running now, before its result is kept.
    private var running: String?
    /// Everything received of the reply being written; `streaming` follows it at an even pace.
    private var target = ""
    private var shown = 0
    private var finalCount = 0
    private var typing: Task<Void, Never>?

    private var demo: Bool { team.phase == .demo }

    init(bot: BotInfo, team: TeamModel) {
        self.bot = bot
        self.team = team
        roomId = nil
        key = TeamModel.key(bot: bot.id)
    }

    init(room: RoomInfo, team: TeamModel) {
        let first = team.bots.first { $0.id == room.members?.first }
        bot = BotInfo(id: room.id, name: room.name, color: first?.color)
        self.team = team
        roomId = room.id
        key = TeamModel.key(room: room.id)
    }

    func open() {
        guard feed == nil else { return }
        if demo {
            if !loaded { lines = Self.demoLines(for: bot) }
            loaded = true
            return
        }
        feed = team.listen(key) { [weak self] event in self?.hear(event) }
        lines = build(team.history(key))
        loaded = true
    }

    func close() {
        if let feed { team.unlisten(feed) }
        feed = nil
        demoReply?.cancel()
        typing?.cancel()
        typing = nil
    }

    // MARK: Even pace

    /// Text arrives in bursts; this lets it out a little each frame, faster when more is waiting.
    private func type() {
        guard typing == nil else { return }
        typing = Task { [weak self] in
            while !Task.isCancelled, let self, self.step() {
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.typing = nil
        }
    }

    /// Lets a few more characters out. False when there is nothing left to let out.
    private func step() -> Bool {
        if let settling = fresh, settling.shown != nil {
            guard shown < finalCount else {
                withAnimation(.easeOut(duration: 0.45)) { fresh?.shown = nil }
                return false
            }
            shown = min(finalCount, shown + max(1, (finalCount - shown) / 10))
            fresh?.shown = shown
            return true
        }
        let goal = target.count
        if shown > goal { shown = goal }
        guard shown < goal else { return false }
        shown = min(goal, shown + max(1, (goal - shown) / 10))
        streaming = String(target.prefix(shown))
        return true
    }

    // MARK: Reading

    func refresh() async {
        guard !demo else { return }
        apply(build(team.history(key)))
    }

    func loadEarlier() async {
        guard hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        limit += 160
        lines = build(team.history(key))
        loadingEarlier = false
    }

    /// The kept messages as rows: what the user said, what the Bot said, and the steps between.
    private func build(_ all: [Entry]) -> [ChatLine] {
        hasEarlier = all.count > limit
        var out: [ChatLine] = []
        var open: Int?
        var openedAt: Double = 0
        var stepAt: Double = 0
        var turnAt: Double?
        var calls: [String: String] = [:]
        var thought = ""
        var feltThisTurn: String?
        for entry in all.suffix(limit) {
            let message = entry.message
            if entry.note == true {
                var note = ChatLine(id: entry.id, kind: .note, text: message.text)
                note.next = entry.next.flatMap(Explain.Next.init(rawValue:))
                out.append(note)
                open = nil
                continue
            }
            switch message.role {
            case .user:
                var line = ChatLine(id: entry.id, kind: .user, text: message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                line.photos = entry.photos.count
                line.refs = entry.photos
                out.append(line)
                open = nil
                turnAt = entry.at
                thought = ""
                feltThisTurn = nil
            case .assistant:
                // 心绪 written before a step with tools belongs to the reply that ends the turn.
                if let felt = entry.pulse, feltThisTurn == nil { feltThisTurn = felt }
                if let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                    thought += (thought.isEmpty ? "" : "\n\n") + reasoning
                }
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var line = ChatLine(id: entry.id, kind: .bot, text: message.text, speaker: entry.speaker)
                    if let turnAt { line.seconds = max(1, Int((entry.at - turnAt) / 1000)) }
                    line.tokens = entry.tokens
                    line.reasoning = thought.isEmpty ? nil : thought
                    line.pulse = feltThisTurn ?? entry.pulse
                    feltThisTurn = nil
                    thought = ""
                    out.append(line)
                    open = nil
                }
                for call in message.toolCalls { calls[call.id] = call.arguments }
                if !message.toolCalls.isEmpty, open == nil {
                    out.append(ChatLine(id: "steps-\(entry.id)", kind: .steps, text: ""))
                    open = out.count - 1
                    openedAt = entry.at
                }
                if !message.toolCalls.isEmpty { stepAt = entry.at }
            case .tool:
                if open == nil {
                    out.append(ChatLine(id: "steps-\(entry.id)", kind: .steps, text: ""))
                    open = out.count - 1
                    openedAt = entry.at
                    stepAt = entry.at
                }
                let input = message.toolCallId.flatMap { calls[$0] } ?? ""
                out[open!].details.append(StepDetail(input: input, output: message.text, seconds: stepAt > 0 ? Int(((entry.at - stepAt) / 1000).rounded()) : nil, photo: entry.photos.first, full: message.detail))
                stepAt = entry.at
                let label = entry.label ?? message.toolName ?? "一步"
                out[open!].tools.append(message.isError ? (message.text.hasPrefix(Agent.unknownMark) ? "\(label)（结果未知）" : "\(label)（没成功）") : label)
                out[open!].seconds = max(1, Int((entry.at - openedAt) / 1000))
            }
        }
        let working = team.isWorking(key)
        if working, let open, open == out.count - 1 {
            out[open].live = true
            if let running { out[open].tools.append(running) }
        }
        for index in out.indices where out[index].kind == .steps {
            let count = out[index].tools.count
            out[index].text = out[index].live ? (count > 0 ? "正在干活，第 \(count) 步" : "正在干活") : "完成 \(count) 步"
        }
        return out
    }

    private func apply(_ next: [ChatLine]) {
        let grew = next.count > lines.count
        if lines != next {
            if loaded && grew && streaming.isEmpty {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { lines = next }
            } else {
                lines = next
            }
        }
    }

    private static func same(_ left: String, _ right: String) -> Bool {
        left.trimmingCharacters(in: .whitespacesAndNewlines) == right.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Live

    private func hear(_ event: TurnEvent) {
        switch event {
        case .pulse(let piece):
            pulse += piece
        case .thinking(let piece):
            thinking += piece
            if thinking.count > 6000 { thinking = String(thinking.suffix(4000)) }
        case .text(let piece):
            if !thinking.isEmpty { thinking = "" }
            if fresh?.shown != nil { fresh?.shown = nil }
            if target.isEmpty { shown = 0 }
            target += piece
            type()
        case .tool(let label):
            thinking = ""
            running = label
            apply(build(team.history(key)))
        case .changed:
            let all = team.history(key)
            if all.last?.message.role == .tool { running = nil }
            let next = build(all)
            let known = Set(lines.map(\.id))
            if !target.isEmpty, let reply = next.last(where: { $0.kind == .bot }), !known.contains(reply.id), Self.same(reply.text, target) {
                // The kept row takes over exactly where the streaming one stood.
                finalCount = reply.text.count
                fresh = Fresh(id: reply.id, shown: shown < finalCount ? shown : nil)
                target = ""
                streaming = ""
                pulse = ""
                lines = next
                if fresh?.shown != nil { type() }
                Haptics.tick(0.6)
            } else {
                if all.last?.note == true {
                    target = ""
                    streaming = ""
                }
                apply(next)
            }
        case .finished:
            running = nil
            thinking = ""
            pulse = ""
            if !target.isEmpty {
                target = ""
                streaming = ""
            }
            apply(build(team.history(key)))
        case .failed(let message):
            thinking = ""
            pulse = ""
            withAnimation(.smooth) { error = message }
            Haptics.lock()
        }
    }

    /// A kept photo. `preview` is ignored: the phone has the whole photo.
    func photo(_ name: String, preview: Bool) async -> Data? {
        Disk.photo(name)
    }

    // MARK: Sending

    func send(_ text: String, photos: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        withAnimation(.smooth) { error = nil }
        if demo { sendDemo(Self.withPhotos(trimmed, photos.count)); return }
        // While the companion works, the message queues and waits; the reply being written is left alone.
        team.send(trimmed, photos: photos, to: key)
    }

    /// 插话: reaches the companion between its steps. Photos can't go in passing; they wait for the turn to end.
    func interject(_ text: String, photos: [Data] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !photos.isEmpty else { return }
        if demo || !photos.isEmpty { send(trimmed, photos: photos); return }
        team.interject(trimmed, to: key)
    }

    /// 中断并发送: stop what it is doing and send this now.
    func sendNow(_ text: String, photos: [Data] = []) {
        send(text, photos: photos)
        team.sendQueueNow(key)
    }

    func retry(_ id: String) {}

    func discard(_ id: String) {
        withAnimation(.smooth) { pending.removeAll { $0.id == id } }
    }

    /// Answers the question a Bot asked: the answer goes in as a message.
    func answer(_ question: Question, selected: [String], custom: String) {
        let text = (selected + [custom.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "，")
        send(text)
    }

    /// Asks the companion to answer the last message again.
    func retry(restoring: Bool = false) {
        guard !demo else { return }
        withAnimation(.smooth) { error = nil }
        target = ""
        streaming = ""
        team.retry(key, restoring: restoring)
    }

    /// Changes something already said, and answers from there.
    func resend(_ id: String, text: String, restoring: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo, !trimmed.isEmpty else { return }
        withAnimation(.smooth) { error = nil }
        target = ""
        streaming = ""
        team.resend(key, entry: id, text: trimmed, restoring: restoring)
    }

    func stop() {
        if demo {
            demoReply?.cancel()
            demoWorking = false
            return
        }
        team.stop(key)
    }

    private static func withPhotos(_ text: String, _ count: Int) -> String {
        count > 0 ? (text.isEmpty ? "［图片 ×\(count)］" : "\(text)\n［图片 ×\(count)］") : text
    }

    // MARK: Demo

    private func sendDemo(_ text: String) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            lines.append(ChatLine(id: "demo-\(UUID().uuidString)", kind: .user, text: text))
        }
        demoReply?.cancel()
        demoReply = Task { [weak self] in
            self?.demoWorking = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            let reply = "这是演示，我还没有接上模型。到设置里填一个 DeepSeek 或 Claude 的密钥，我就能真的回答你：一边想一边写，像现在这样一个字一个字冒出来。"
            self?.shown = 0
            self?.fresh = nil
            var rest = Substring(reply)
            while !rest.isEmpty, !Task.isCancelled {
                let burst = rest.prefix(Int.random(in: 4...14))
                rest = rest.dropFirst(burst.count)
                self?.target.append(contentsOf: burst)
                self?.type()
                try? await Task.sleep(nanoseconds: 260_000_000)
            }
            guard let self else { return }
            let said = Task.isCancelled ? self.streaming : self.target
            self.target = ""
            if said.isEmpty {
                self.streaming = ""
            } else {
                let line = ChatLine(id: "demo-\(UUID().uuidString)", kind: .bot, text: said)
                self.finalCount = said.count
                self.lines.append(line)
                self.fresh = Fresh(id: line.id, shown: self.shown < said.count ? self.shown : nil)
                self.streaming = ""
                self.type()
            }
            self.demoWorking = false
            Haptics.tick(0.6)
        }
    }

    private static func demoLines(for bot: BotInfo) -> [ChatLine] {
        [
            ChatLine(id: "d1", kind: .user, text: "这周六想和朋友去磁器口，帮我看看天气，顺便记进日历"),
            ChatLine(id: "d2", kind: .steps, text: "完成 3 步", tools: ["搜索：重庆 周六 天气", "读网页：weather.com.cn", "新建日程：去磁器口"]),
            ChatLine(id: "d3", kind: .bot, text: "周六重庆**多云转小雨**，14–19 度，记得带伞 ☂️\n\n- 日程已经加好：周六 10:00 磁器口\n- 出门前一小时提醒你\n\n来源：中国天气网"),
        ]
    }
}

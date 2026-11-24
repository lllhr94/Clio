import AgentKit
import Craft
import Observation
import SwiftUI

/// One step of a trace, opened up.
struct StepDetail: Equatable, Sendable {
    var input: String
    var output: String
    var seconds: Int?
    /// A picture the step brought back, such as a page's screenshot (a kept photo's name).
    var photo: String?
    /// For the person only: a changed file's whole comparison.
    var full: String?
    /// Raw tool identifier (e.g. `write_file`, `shell`), kept so trace cards do not depend on display wording.
    var tool: String? = nil
}

/// One row of a chat.
struct ChatLine: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case user, bot, steps, note }
    enum Local: Sendable { case sending, failed }

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
    /// A compression line: drawn as a divider, the chat above it still there.
    var fold = false
    /// When it was said (milliseconds), for the time between turns.
    var at: Double?
}

/// The chat with one Bot or one group: shows it, keeps it live, sends into it.
@MainActor @Observable
final class ChatModel {
    private(set) var lines: [ChatLine] = []
    private(set) var pending: [ChatLine] = []
    /// The part of the reply being written that is on screen so far.
    private(set) var streamGeneration = 0
    private(set) var streaming = "" {
        didSet {
            if streaming.isEmpty && !oldValue.isEmpty { streamGeneration += 1 }
            let writing = !streaming.isEmpty
            if writing != hasStreaming { hasStreaming = writing }
        }
    }
    private(set) var hasStreaming = false
    /// What the model is thinking right now, before it answers or between steps. Cleared once it moves on.
    private(set) var thinking = ""
    @ObservationIgnored private var pendingThought = ""
    @ObservationIgnored private var thoughtUpdate: Task<Void, Never>?
    /// The 心绪 being written before the reply in progress.
    private(set) var pulse = ""
    private(set) var pulseSpeaker: String?
    /// The reply that just finished: the row that took over from the streaming one.
    private(set) var fresh: Fresh?

    struct Fresh: Equatable {
        var id: String
        /// How many characters are out so far; nil once the whole reply is.
        var shown: Int?
    }
    private(set) var loaded = false
    private(set) var demoWorking = false
    var error: String?

    private(set) var earlier: [ChatLine] = []
    private(set) var hasEarlier = false
    private(set) var loadingEarlier = false

    /// The Bot this chat is with. For a group: a stand-in that carries the group's name.
    let bot: BotInfo
    /// Set when this is a group chat.
    let roomId: String?
    /// Where the team keeps this chat.
    let key: String
    var sessionId: String { key }

    private let team: TeamModel
    private var feed: UUID?
    private var opening: Task<Void, Never>?
    private var demoReply: Task<Void, Never>?
    /// How many kept messages are on screen.
    private var limit = 160
    /// The tool running now, before its result is kept.
    private var running: String?
    @ObservationIgnored private var toolRows: Task<Void, Never>?
    private var browsingHistory = false
    private var heldRows: [ChatLine]?
    /// Everything received of the reply being written; `streaming` follows it at an even pace.
    private var target = ""
    private var shown = 0
    private var publishedShown = 0
    private var finalCount = 0
    /// When the text on the page last changed. Characters still come out every frame, but the page is redrawn at
    /// most `Self.redraws` times a second: redrawing a long reply sixty times a second is what made it stutter.
    private var published: TimeInterval = 0
    private static let redraws = 15.0

    private func due() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - published >= 1 / Self.redraws else { return false }
        published = now
        return true
    }
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
        guard feed == nil, opening == nil else { return }
        if demo {
            if !loaded { lines = Self.demoLines(for: bot) }
            loaded = true
            return
        }
        opening = Task { [weak self] in
            guard let self else { return }
            let history = await team.loadHistory(key)
            guard !Task.isCancelled else { return }
            let pageLimit = limit
            var firstPage: [ChatLine]?
            if !team.isWorking(key), !history.isEmpty {
                firstPage = await Task.detached(priority: .userInitiated) {
                    Self.buildRows(history.suffix(pageLimit), working: false, running: nil)
                }.value
                guard !Task.isCancelled else { return }
            }
            feed = team.listen(key) { [weak self] event in self?.hear(event) }
            let newest = team.history(key)
            if let firstPage, pageLimit == limit, !team.isWorking(key), history == newest {
                hasEarlier = history.count > pageLimit
                lines = firstPage
            } else {
                lines = build(newest)
            }
            loaded = true
            opening = nil
        }
    }

    func close() {
        cancelToolRows()
        opening?.cancel()
        opening = nil
        if let feed { team.unlisten(feed) }
        feed = nil
        browsingHistory = false
        heldRows = nil
        demoReply?.cancel()
        clearThinking()
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
                // The same layout stays in place. No crossfade over the finished text.
                fresh?.shown = nil
                return false
            }
            shown = min(finalCount, shown + max(1, (finalCount - shown) / 10))
            if shown >= finalCount || due() { fresh?.shown = shown }
            return true
        }
        let goal = target.count
        if shown > goal { shown = goal }
        if shown < goal { shown = min(goal, shown + max(1, (goal - shown) / 10)) }
        if shown > publishedShown, due() {
            streaming = String(target.prefix(shown))
            publishedShown = shown
        }
        return shown < goal || publishedShown < shown
    }

    // MARK: Reading

    func refresh() async {
        guard !demo else { return }
        cancelToolRows()
        apply(build(team.history(key)))
    }

    /// A read-only lookup snapshot. It must never enlarge the window used by live updates.
    func lookupRows() async -> [ChatLine] {
        let history = await team.loadHistory(key)
        return await Task.detached(priority: .userInitiated) {
            Self.buildRows(history[...], working: false, running: nil)
        }.value
    }

    func loadEarlier() async {
        guard hasEarlier, !loadingEarlier else { return }
        cancelToolRows()
        loadingEarlier = true
        defer { loadingEarlier = false }
        let epoch = team.epochs[key, default: 0]
        let nextLimit = limit + 160
        let history = await team.loadHistory(key)
        let working = team.isWorking(key)
        let tool = running
        let page = await Task.detached(priority: .userInitiated) {
            Self.buildRows(history.suffix(nextLimit), working: working, running: tool)
        }.value
        guard !Task.isCancelled, team.epochs[key, default: 0] == epoch else { return }
        // A tool event may have started another build while the larger page was being prepared.
        cancelToolRows()
        limit = nextLimit
        heldRows = nil
        let newest = team.history(key)
        if newest == history, working == team.isWorking(key), tool == running {
            hasEarlier = newest.count > limit
            lines = page
        } else {
            lines = build(newest)
        }
    }

    /// The kept messages as rows: what the user said, what the Bot said, and the steps between.
    private func build(_ all: [Entry]) -> [ChatLine] {
        hasEarlier = all.count > limit
        return Self.buildRows(all.suffix(limit), working: team.isWorking(key), running: running)
    }

    nonisolated private static func buildRows(_ entries: ArraySlice<Entry>, working: Bool, running: String?) -> [ChatLine] {
        var out: [ChatLine] = []
        var open: Int?
        var openedAt: Double = 0
        var stepAt: Double = 0
        var turnAt: Double?
        var calls: [String: String] = [:]
        var thought = ""
        var feltThisTurn: String?
        for entry in entries {
            if Task.isCancelled { return [] }
            let message = entry.message
            if entry.note == true {
                var note = ChatLine(id: entry.id, kind: .note, text: message.text)
                note.next = entry.next.flatMap(Explain.Next.init(rawValue:))
                note.fold = entry.fold == true
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
                out[open!].details.append(StepDetail(input: input, output: message.text, seconds: stepAt > 0 ? Int(((entry.at - stepAt) / 1000).rounded()) : nil, photo: entry.photos.first, full: message.detail, tool: message.toolName))
                stepAt = entry.at
                let label = entry.label ?? message.toolName ?? "一步"
                out[open!].tools.append(message.isError ? (message.text.hasPrefix(Agent.unknownMark) ? "\(label)（结果未知）" : "\(label)（没成功）") : label)
                out[open!].seconds = max(1, Int((entry.at - openedAt) / 1000))
            }
        }
        if working, let open, open == out.count - 1 {
            out[open].live = true
            if let running { out[open].tools.append(running) }
        }
        for index in out.indices where out[index].kind == .steps {
            let count = out[index].tools.count
            out[index].text = out[index].live ? (count > 0 ? "正在干活，第 \(count) 步" : "正在干活") : "完成 \(count) 步"
        }
        let stamps = Dictionary(entries.map { ($0.id, $0.at) }, uniquingKeysWith: { first, _ in first })
        for index in out.indices { out[index].at = stamps[out[index].id] }
        return out
    }

    func setBrowsingHistory(_ browsing: Bool) {
        guard browsingHistory != browsing else { return }
        browsingHistory = browsing
        if !browsing, let heldRows {
            self.heldRows = nil
            apply(heldRows)
        }
    }

    private func apply(_ next: [ChatLine]) {
        if browsingHistory {
            heldRows = next
            return
        }
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

    private func showThinking(_ piece: String) {
        guard !piece.isEmpty else { return }
        if thinking.isEmpty {
            thinking = piece.count > 6000 ? String(piece.suffix(4000)) : piece
            return
        }
        pendingThought += piece
        guard thoughtUpdate == nil else { return }
        thoughtUpdate = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            let next = self.thinking + self.pendingThought
            self.pendingThought = ""
            self.thoughtUpdate = nil
            self.thinking = next.count > 6000 ? String(next.suffix(4000)) : next
        }
    }

    private func clearThinking() {
        thoughtUpdate?.cancel()
        thoughtUpdate = nil
        pendingThought = ""
        if !thinking.isEmpty { thinking = "" }
    }

    private func cancelToolRows() {
        toolRows?.cancel()
        toolRows = nil
    }

    private func rebuildToolRows(_ history: [Entry]) {
        cancelToolRows()
        let pageLimit = limit
        let epoch = team.epochs[key, default: 0]
        let working = team.isWorking(key)
        let label = running
        toolRows = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.buildRows(history.suffix(pageLimit), working: working, running: label)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.toolRows = nil
            guard self.limit == pageLimit, self.team.epochs[self.key, default: 0] == epoch else { return }
            let current = self.team.history(self.key)
            guard self.running == label, self.team.isWorking(self.key) == working, current == history else {
                self.rebuildToolRows(current)
                return
            }
            self.hasEarlier = current.count > pageLimit
            self.apply(next)
        }
    }

    private func hear(_ event: TurnEvent) {
        switch event {
        case .pulse(let piece, let speaker):
            if pulseSpeaker != speaker { pulseSpeaker = speaker }
            pulse += piece
        case .thinking(let piece):
            showThinking(piece)
        case .text(let piece):
            clearThinking()
            if fresh?.shown != nil { fresh?.shown = nil }
            if target.isEmpty { shown = 0; publishedShown = 0 }
            target += piece
            type()
        case .tool(let label):
            clearThinking()
            running = label
            rebuildToolRows(team.history(key))
        case .changed:
            let all = team.history(key)
            if all.last?.message.role == .tool { running = nil }
            if target.isEmpty, let last = all.last?.message,
               last.role == .tool || (last.role == .assistant && last.text.isEmpty && !last.toolCalls.isEmpty) {
                rebuildToolRows(all)
                return
            }
            cancelToolRows()
            let next = build(all)
            if !target.isEmpty, let reply = next.last(where: { $0.kind == .bot }), !lines.contains(where: { $0.id == reply.id }) {
                // The kept row takes over exactly where the streaming one stood. Not only when the words match to
                // the letter: the kept text can differ a little (a 心绪 taken out, trailing spaces, a sources list
                // tidied), and waiting for an exact match left both rows up, then dropped the streaming one, so the
                // answer seemed to vanish and come back.
                finalCount = reply.text.count
                if !Self.same(reply.text, target) { shown = min(shown, finalCount) }
                fresh = Fresh(id: reply.id, shown: shown < finalCount ? shown : nil)
                target = ""
                streaming = ""
                pulse = ""
                heldRows = nil
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
            clearThinking()
            pulse = ""
            if !target.isEmpty {
                target = ""
                streaming = ""
            }
            rebuildToolRows(team.history(key))
        case .failed(let message):
            cancelToolRows()
            clearThinking()
            pulse = ""
            withAnimation(.smooth) { error = message }
            Haptics.lock()
        }
    }

    /// A kept photo. `preview` is ignored: the phone has the whole photo.
    func photo(_ name: String, preview: Bool) async -> Data? {
        await Task.detached(priority: .userInitiated) { Disk.photo(name) }.value
    }

    // MARK: Sending

    @discardableResult
    func send(_ text: String, photos: [Data] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !photos.isEmpty else { return false }
        withAnimation(.smooth) { error = nil }
        if demo { sendDemo(Self.withPhotos(trimmed, photos.count)); return true }
        // While the companion works, the message queues and waits; the reply being written is left alone.
        return team.send(trimmed, photos: photos, to: key)
    }

    /// 插话: reaches the companion between its steps. Photos can't go in passing; they wait for the turn to end.
    @discardableResult
    func interject(_ text: String, photos: [Data] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !photos.isEmpty else { return false }
        if demo || !photos.isEmpty { return send(trimmed, photos: photos) }
        return team.interject(trimmed, to: key)
    }

    /// 中断并发送: stop what it is doing and send this now.
    @discardableResult
    func sendNow(_ text: String, photos: [Data] = []) -> Bool {
        guard send(text, photos: photos) else { return false }
        team.sendQueueNow(key)
        return true
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
    @discardableResult
    func resend(_ id: String, text: String, restoring: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo, !trimmed.isEmpty else { return false }
        guard team.canAcceptInput(for: key) else { return false }
        withAnimation(.smooth) { error = nil }
        target = ""
        streaming = ""
        return team.resend(key, entry: id, text: trimmed, restoring: restoring)
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

    /// What the 「reply arriving」 screenshot streams: a loose list and a table with a gap, the cases that used to break.
    private static let shotReply = """
    要带的东西：

    - 雨伞，下午三点后有雨

    - 充电宝，拍照费电

    - 一件薄外套

    | 东西 | 谁带 |
    | :-- | :-- |
    | 雨伞 | 你 |
    | 零食 | 朋友 |
    | 水 | 都带 |

    其余的到了再买，重庆什么都方便。再补一句很长的话，让这段回答在截图的时候还在一个字一个字地往外冒，看看页面会不会突然空白或者跳动。
    """

    static let shotQuestionID = "shot-c33-question"

    /// Same question and common blocks in both frames. Stage the reply after the chat is on screen so the
    /// screenshot can hold steady at each point in the same renderer.
    func stageReplyShot(_ stage: Shots.StreamStage) {
        guard demo else { return }
        let heading = """
        要带的东西：

        - 雨伞，下午三点后有雨

        - 充电宝，拍照费电

        | 东西 | 谁带 |
        | :-- | :-- |
        | 雨伞 | 你 |
        | 水 | 都带 |

        ```text
        出发前：充好电，带上水。
        ```
        """
        let end = """
        到了再买零食。约在地铁口碰面，带件薄外套，回程路上会凉一点。
        明早再看一次天气，如果一直下雨，我们就把午饭改到室内。

        行程改完以后把地址同步给同行的人，免得大家跑错地方。
        """
        let prefix = heading + "\n\n"
        lines.append(ChatLine(id: Self.shotQuestionID, kind: .user, text: "再帮我列个要带的东西"))
        switch stage {
        case .midway:
            demoWorking = true
            streaming = prefix + end.prefix(12)
        case .finished:
            let line = ChatLine(id: "shot-c33-reply", kind: .bot, text: prefix + end)
            fresh = Fresh(id: line.id, shown: nil)
            lines.append(line)
        }
    }

    private func sendDemo(_ text: String) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            lines.append(ChatLine(id: "demo-\(UUID().uuidString)", kind: .user, text: text))
        }
        demoReply?.cancel()
        demoReply = Task { [weak self] in
            self?.demoWorking = true
            let shot = Shots.name == "chat-stream"
            try? await Task.sleep(nanoseconds: shot ? 300_000_000 : 900_000_000)
            let reply = shot ? Self.shotReply : "这是演示，我还没有接上模型。到设置里填一个 DeepSeek 或 Claude 的密钥，我就能真的回答你：一边想一边写，像现在这样一个字一个字冒出来。"
            self?.shown = 0
            self?.publishedShown = 0
            self?.fresh = nil
            var rest = Substring(reply)
            while !rest.isEmpty, !Task.isCancelled {
                let burst = rest.prefix(Int.random(in: 4...14))
                rest = rest.dropFirst(burst.count)
                self?.target.append(contentsOf: burst)
                self?.type()
                try? await Task.sleep(nanoseconds: shot ? 120_000_000 : 260_000_000)
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
        ] + (Shots.name?.hasPrefix("chat-") == true ? longDemo : [])
    }

    /// For the screenshots of a long conversation: many more turns, with every kind of block a reply can have.
    private static var longDemo: [ChatLine] {
        let code = (1...26).map { "    print(\"第 \($0) 行\")" }.joined(separator: "\n")
        return (1...6).flatMap { round -> [ChatLine] in
            [
                ChatLine(id: "long-u\(round)", kind: .user, text: "第 \(round) 个问题：帮我把这些整理一下，顺便写段代码"),
                ChatLine(id: "long-b\(round)", kind: .bot, text: """
                好，分三块说。

                - **先说结论**：第 \(round) 轮的要点在下面

                - 中间隔了一行的列表项，也要连在一起

                - 第三项，带一点 `行内代码`

                | 项目 | 数量 | 备注 |
                | :-- | --: | :-- |
                | 甲 | 12 | 第一行 |
                | 乙 | 7 | 第二行 |

                > 引用一句：慢慢来，比较快。

                ```swift
                func greet() {
                \(code)
                }
                ```

                公式也试一下：

                $$E = mc^2$$

                最后一段正文，长一点，看换行和行距是不是舒服：路线、天气、要带的东西，我都写进书案了，想改哪一段直接告诉我。
                """),
            ]
        }
    }
}

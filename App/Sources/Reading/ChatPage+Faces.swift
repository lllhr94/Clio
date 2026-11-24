import AVFoundation
import AgentKit
import CoreLocation
import Craft
import NaturalLanguage
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: Faces

    static let face: CGFloat = 32

    /// Who said a line, for faces: you, or the companion (in a group, the one who spoke). Steps belong to the reply.
    func voice(_ line: ChatLine) -> String? {
        switch line.kind {
        case .user: return "me"
        case .bot, .steps: return "bot:" + (line.speaker ?? bot.id)
        case .note: return nil
        }
    }

    /// The lines that open a run by one speaker: only they carry a face, so a reply in several parts shows it once.
    var openers: Set<String> {
        sourcesMemo.sync(rows: displayedRows, defaultBotId: bot.id)
        return sourcesMemo.openers
    }

    /// A line with its face: the companion's above its reply, yours beside your bubble, and the time when a while has passed.
    @ViewBuilder
    func turnRow(_ line: ChatLine, opens: Bool, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if faces, opens, let gap = timeGap(before: line) {
                Text(gap)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Ink.Space.xs)
            }
            switch line.kind {
            case .user:
                if faces {
                    HStack(alignment: .top, spacing: Ink.Space.s) {
                        row(line)
                        if opens {
                            MeAvatar(size: Self.face)
                        } else {
                            Color.clear.frame(width: Self.face, height: 1)
                        }
                    }
                } else {
                    row(line)
                }
            case .bot, .steps:
                // Without faces, a group still says who is speaking, small.
                if opens, faces || isRoom { speakerHead(line) }
                row(line)
            case .note:
                row(line)
            }
        }
        // The place found: a soft ground behind it, so the eye lands there.
        .background {
            if lit {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.accentWash)
                    .padding(-Ink.Space.s)
            }
        }
        .animation(Ink.Motion.settle, value: lit)
    }

    /// The companion's face and name, over what it says.
    func speakerHead(_ line: ChatLine) -> some View {
        let speaker = line.speaker.flatMap { id in team.bots.first { $0.id == id } } ?? (isRoom ? nil : bot)
        return HStack(spacing: Ink.Space.s) {
            PetStill(size: faces ? Self.face : 22, wash: speaker.map { Ink.wash(for: $0) }, avatar: true, bot: speaker)
            Text(speaker?.name ?? line.speakerName ?? bot.name)
                .font(.system(size: Ink.Size.small, weight: .semibold))
                .foregroundStyle(Ink.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    /// 「昨天 23:10」 over a line said more than half an hour after the one before it.
    func timeGap(before line: ChatLine) -> String? {
        let rows = displayedRows
        sourcesMemo.sync(rows: rows, defaultBotId: bot.id)
        guard let at = line.at,
              let index = sourcesMemo.indexById[line.id], index > 0,
              let before = rows[..<index].last(where: { $0.at != nil })?.at,
              at - before > 30 * 60 * 1000 else { return nil }
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "昨天 " + clock }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day()) + " " + clock
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day()) + " " + clock
    }

    /// Where a compression happened: a quiet divider. Above it everything is still here; tap to read the 前情提要.
    func foldLine(_ line: ChatLine) -> some View {
        Button {
            Haptics.light()
            leafing = true
        } label: {
            HStack(spacing: Ink.Space.s) {
                Rectangle().fill(Ink.rule).frame(height: 1)
                Label(line.text, systemImage: "text.append")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Ink.rule).frame(height: 1)
            }
            .padding(.vertical, Ink.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .accessibilityLabel(line.text + "，点开看前情提要")
    }

    /// A failure, said plainly, with the one thing to do about it. Only the latest one keeps its button.
    func trouble(_ line: ChatLine, next: Explain.Next) -> some View {
        let parts = line.text.split(separator: "\n", maxSplits: 1).map(String.init)
        let latest = chat.lines.last(where: { $0.kind == .note })?.id == line.id && chat.lines.last?.id == line.id
        let advice = Explain.Advice(title: parts.first ?? line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            // A pause is not a failure: said in ink, not in red.
            Label(advice.displayTitle, systemImage: next == .resume ? "pause.circle" : "exclamationmark.triangle")
                .font(.system(size: Ink.Size.sub, weight: .semibold))
                .foregroundStyle(next == .resume ? Ink.ink : Ink.stop)
            if !advice.detail.isEmpty {
                Text(advice.detail).font(Ink.secondary).foregroundStyle(Ink.inkSoft)
            }
            if latest, let button = advice.button {
                Button {
                    Haptics.light()
                    act(next)
                } label: {
                    Text(button)
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .padding(.horizontal, Ink.Space.l)
                        .frame(height: 34)
                        .background(Ink.accentWash, in: .capsule)
                }
                .buttonStyle(PressStyle(haptic: false))
                .padding(.top, Ink.Space.xs)
            }
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(next == .resume ? Ink.paperRaised.opacity(0.7) : Ink.stop.opacity(0.07), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
    }

    struct UndoAsk: Identifiable {
        let id = UUID()
        /// Nil: a retry of the last answer. Otherwise the edited message.
        var entry: String?
        var text: String?
        var files: [String]
    }

    /// 重来一次, or 改了重发: when that turn changed files, first ask whether they go back too.
    @discardableResult
    func redo(from entry: String? = nil, text: String? = nil) -> Bool {
        guard !sendingBlocked else { return false }
        following = true
        let changed = team.changedFiles(chat.key, from: entry)
        guard !changed.isEmpty else {
            if let entry, let text { return chat.resend(entry, text: text) }
            chat.retry()
            return true
        }
        undoAsk = UndoAsk(entry: entry, text: text, files: changed.map { WorkPlace(code: $0.place).title + "：" + $0.path })
        return true
    }

    func finishRedo(_ ask: UndoAsk, restoring: Bool) {
        following = true
        if let entry = ask.entry, let text = ask.text { chat.resend(entry, text: text, restoring: restoring) } else { chat.retry(restoring: restoring) }
    }

    func act(_ next: Explain.Next) {
        switch next {
        case .retry: redo()
        case .resume:
            following = true
            team.resume(chat.key)
        case .tuning: tuningOpen = true
        case .care: careOpen = true
        case .compress:
            say(L.t("loading.compactingContext"))
            Task {
                do {
                    let folded = try await team.compress(chat.key)
                    say("压好了：较早的 \(folded) 条写成了提要。再发一次试试。")
                } catch {
                    say(error.localizedDescription)
                }
            }
        }
    }

    /// A first line 「回望：…」 taken off the reply, and the rest.
    static func lookback(_ text: String) -> (note: String?, rest: String) {
        let trimmed = text.drop { $0 == "\n" || $0 == " " }
        let probe = trimmed.drop { $0 == "*" || $0 == " " }
        guard probe.hasPrefix("回望") else { return (nil, text) }
        guard let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return (nil, text) }
        let line = first.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        for head in ["回望：", "回望:"] where line.hasPrefix(head) {
            let note = String(line.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
            let rest = trimmed.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return (note.isEmpty ? nil : note, rest)
        }
        return (nil, text)
    }

    /// Your bubble's tint: the paper's tone, the colour picked in 外观, or the accent wash while editing.
    func bubbleTint(editing: Bool) -> Color {
        if editing { return Ink.accentWash }
        return Ink.bubble
    }

    /// No more of the companion's words follow before the user speaks again.
    func endsTurn(_ line: ChatLine) -> Bool {
        sourcesMemo.sync(rows: displayedRows, defaultBotId: bot.id)
        if sourcesMemo.indexById[line.id] == nil { return true }
        return sourcesMemo.turnEnds.contains(line.id)
    }

    func fork(at line: ChatLine) {
        Haptics.thud()
        team.fork(chat.key, at: line.id)
    }

    /// The same actions on every reply, by a long press: the footer only sits under the last one.
    @ViewBuilder
    /// What ⋯ under a reply holds. Copying the whole reply is the icon beside it, so it is not here again.
    func replyMenu(_ line: ChatLine) -> some View {
        Button("朗读", systemImage: "speaker.wave.2") { speak(line.text) }
        Button("引用追问", systemImage: "text.quote") { quoting = Noting(id: line.id, text: line.text) }
        Button(L.t("saveNote.title"), systemImage: "square.and.arrow.down.on.square") { savingNote = Noting(id: line.id, text: line.text) }
        Button(Words.t("做成长图"), systemImage: "photo.on.rectangle") { noting = Noting(id: line.id, text: line.text) }
        ShareLink(item: line.text) { Label("分享", systemImage: "square.and.arrow.up") }
        if !isRoom {
            Button(Words.t("从这里另起一叶"), systemImage: "arrow.triangle.branch") { fork(at: line) }
        }
    }

    func footer(_ line: ChatLine, newest: Bool = true) -> some View {
        HStack(spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.xs) {
                icon("doc.on.doc", "复制") {
                    UIPasteboard.general.string = line.text
                    Haptics.tick(0.5)
                    say("复制好了。")
                }
                if newest {
                    icon("arrow.clockwise", "重来一次") {
                        Haptics.light()
                        redo()
                    }
                }
                // The rest waits behind ⋯, so the row stays short like other apps'.
                Menu {
                    replyMenu(line)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkFaint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
            }
            .overlay {
                if newest {
                    Color.clear
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                            petPerch.replyActionsOwner = line.id
                            petPerch.replyActions = rect
                        }
                        .onChange(of: following, initial: true) { _, resting in petPerch.avoidsReplies = resting }
                        .onDisappear {
                            if petPerch.replyActionsOwner == line.id {
                                petPerch.replyActionsOwner = nil
                                petPerch.replyActions = .null
                            }
                        }
                }
            }
            Spacer(minLength: Ink.Space.s)
            if newest, Pref.stats {
                Text(Self.numbers(line))
                    .font(.system(size: Ink.Size.micro).monospacedDigit())
                    .foregroundStyle(Ink.inkFaint.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .padding(.leading, -5)
    }

    /// 「2分31秒 · 6.4k tokens」: how long the turn took and how much was written, short enough for one line.
    static func numbers(_ line: ChatLine) -> String {
        var parts: [String] = []
        if let seconds = line.seconds { parts.append(Clock.said(seconds)) }
        if let tokens = line.tokens {
            parts.append(tokens >= 1000 ? String(format: "%.1fk tokens", Double(tokens) / 1000) : "\(tokens) tokens")
        } else {
            let count = line.text.count
            parts.append(count >= 1000 ? String(format: "%.1f千字", Double(count) / 1000) : "\(count)字")
        }
        return parts.joined(separator: " · ")
    }

    func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Ink.Size.small, weight: .regular))
                .foregroundStyle(Ink.inkFaint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }

    func speak(_ text: String) {
        if dictation.busy {
            dictation.cancel()
        }
        if voice.isSpeaking {
            _ = voice.stopSpeaking(at: .immediate)
            if speakingText == text {
                speakingText = nil
                return
            }
        }
        speakingText = text
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        func stripMarkdownBlocks(_ raw: String, dropCodeBlocks: Bool) -> String {
            var source = raw
            if dropCodeBlocks {
                source = source.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
                source = source.replacingOccurrences(of: #"`[^`\n]+`"#, with: " ", options: .regularExpression)
                source = source.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            } else {
                source = source.replacingOccurrences(of: #"(?m)^[ \t]*```[^\n]*\n?"#, with: "", options: .regularExpression)
            }
            source = source.replacingOccurrences(of: #"(?m)^[ \t]*#{1,6}[ \t]+"#, with: "", options: .regularExpression)
            source = source.replacingOccurrences(of: #"(?m)^[ \t]*>[ \t]?"#, with: "", options: .regularExpression)
            source = source.replacingOccurrences(of: #"(?m)^[ \t]*[-*_]{3,}[ \t]*$"#, with: "", options: .regularExpression)
            let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? source
            return parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func redactSecrets(_ raw: String) -> String {
            var out = raw
            for secret in Vault.allStrings() where secret.count >= 6 {
                if out.contains(secret) {
                    out = out.replacingOccurrences(of: secret, with: "（已跳过密钥）")
                }
            }
            return out
        }

        func mapLanguage(_ lang: NLLanguage) -> String? {
            switch lang {
            case .simplifiedChinese: return "zh-CN"
            case .traditionalChinese: return "zh-TW"
            case .english: return "en-US"
            case .japanese: return "ja-JP"
            case .korean: return "ko-KR"
            case .french: return "fr-FR"
            case .german: return "de-DE"
            case .spanish: return "es-ES"
            case .italian: return "it-IT"
            case .portuguese: return "pt-BR"
            case .russian: return "ru-RU"
            case .arabic: return "ar-SA"
            case .thai: return "th-TH"
            case .vietnamese: return "vi-VN"
            case .indonesian: return "id-ID"
            case .dutch: return "nl-NL"
            case .polish: return "pl-PL"
            case .turkish: return "tr-TR"
            case .hindi: return "hi-IN"
            case .undetermined: return nil
            default: return lang.rawValue
            }
        }

        func scriptCounts(for sample: String) -> (cjk: Int, kana: Int, hangul: Int, latin: Int) {
            var cjk = 0
            var kana = 0
            var hangul = 0
            var latin = 0
            for scalar in sample.unicodeScalars {
                let v = scalar.value
                if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                    kana += 1
                } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                    hangul += 1
                } else if scalar.properties.isIdeographic {
                    cjk += 1
                } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                    latin += 1
                }
            }
            return (cjk, kana, hangul, latin)
        }

        func scriptFallbackLanguage(counts: (cjk: Int, kana: Int, hangul: Int, latin: Int)) -> String {
            if counts.kana > 0 && counts.kana + counts.cjk >= counts.hangul { return "ja-JP" }
            if counts.hangul > 0 && counts.hangul >= counts.cjk { return "ko-KR" }
            if counts.cjk > 0 { return "zh-CN" }
            if counts.latin > 0 { return "en-US" }
            return "zh-CN"
        }

        func detectLanguage(for sample: String) -> String {
            let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "zh-CN" }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmed)

            let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
            let dominant = recognizer.dominantLanguage
            let counts = scriptCounts(for: trimmed)

            if counts.kana > 0 && (dominant == .japanese || (hypotheses[.japanese] ?? 0) >= 0.15) {
                return "ja-JP"
            }
            if counts.hangul > 0 && (dominant == .korean || (hypotheses[.korean] ?? 0) >= 0.15) {
                return "ko-KR"
            }

            let totalScript = counts.cjk + counts.kana + counts.hangul + counts.latin
            if counts.cjk >= 2 && counts.kana == 0 && totalScript > 0 {
                let cjkRatio = Double(counts.cjk) / Double(totalScript)
                let zhWeight = (hypotheses[.simplifiedChinese] ?? 0) + (hypotheses[.traditionalChinese] ?? 0)
                if cjkRatio >= 0.15 || (counts.cjk >= 4 && zhWeight >= 0.12) {
                    if (hypotheses[.traditionalChinese] ?? 0) > (hypotheses[.simplifiedChinese] ?? 0) {
                        return "zh-TW"
                    }
                    return "zh-CN"
                }
            }

            if let dominant, let mapped = mapLanguage(dominant) {
                return mapped
            }
            if let top = hypotheses.max(by: { $0.value < $1.value }), top.value >= 0.35, let mapped = mapLanguage(top.key) {
                return mapped
            }
            return scriptFallbackLanguage(counts: counts)
        }

        let redactedInput = redactSecrets(text)
        let plain = redactSecrets(stripMarkdownBlocks(redactedInput, dropCodeBlocks: false))
        let proseSample = redactSecrets(stripMarkdownBlocks(redactedInput, dropCodeBlocks: true))
        let detectionInput = proseSample.isEmpty ? plain : proseSample
        let detected = detectLanguage(for: detectionInput)

        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: detected) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        voice.speak(utterance)
    }
}

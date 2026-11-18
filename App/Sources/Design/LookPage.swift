import SwiftUI
import UIKit

/// 纸墨与絮语: how Clio looks, how it feels in the hand, and how conversations are carried.
struct LookPage: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("look.face") private var face = "song"
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.leading") private var leading = 8.0
    @AppStorage("look.haptics") private var haptics = true
    @AppStorage("look.fade") private var fade = true
    @AppStorage("look.stats") private var stats = true
    @AppStorage("look.traceOpen") private var traceOpen = false
    @AppStorage("mascot.shown") private var mascot = true

    @AppStorage("chat.autoCompress") private var autoCompress = true
    @AppStorage("chat.compressAt") private var compressAt = 60_000
    @AppStorage("chat.keepRecent") private var keepRecent = 12
    @AppStorage("chat.contextChars") private var contextChars = 48_000
    @AppStorage("chat.contextCount") private var contextCount = 0
    @AppStorage("chat.temperature") private var temperature = -1.0
    @AppStorage("chat.maxOutput") private var maxOutput = 0
    @AppStorage("morning.on") private var morningOn = false
    @AppStorage("diary.on") private var diaryOn = false
    @AppStorage("morning.hour") private var morningHour = 7
    @AppStorage("notify.done") private var notifyDone = true
    @AppStorage("live.on") private var liveOn = true
    @AppStorage("look.fps") private var fps = false
    @State private var icon = UIApplication.shared.alternateIconName
    @State private var iconNote: String?

    /// 桌面图标: the companion in other colors. Nil is the usual one.
    private static let iconChoices: [(name: String?, preview: String, title: String)] = [
        (nil, "IconPreview-Default", "晴蓝"),
        ("AppIcon-Rose", "IconPreview-Rose", "桃粉"),
        ("AppIcon-Mint", "IconPreview-Mint", "薄荷"),
        ("AppIcon-Honey", "IconPreview-Honey", "蜂蜜"),
        ("AppIcon-Lilac", "IconPreview-Lilac", "丁香"),
        ("AppIcon-Night", "IconPreview-Night", "夜色"),
    ]

    private let sample = """
    ## 小样
    窗外落了一阵**细雨**，案头的茶还温着。这里是正文的模样：字体、字号与行距都会照你的选择变。

    - 列表也随之更换
    - 行内的 `代码` 保持等宽
    """

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    ProseView(text: sample)
                        .padding(.vertical, Ink.Space.s)
                        .listRowBackground(Ink.paperRaised)
                } header: { Text("小样") }

                Section("纸墨") {
                    Picker("明暗", selection: $scheme) {
                        Text("跟随系统").tag("system")
                        Text("纸白").tag("light")
                        Text("夜墨").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Picker("正文字体", selection: $face) {
                        ForEach(Pref.Face.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(title: "字号", value: $size, range: 14...23, step: 1) { "\(Int($0))" }
                    LabeledSlider(title: "行距", value: $leading, range: 2...16, step: 1) { "\(Int($0))" }
                    palettes
                    icons
                }

                Section("动静") {
                    Toggle("触感反馈", isOn: $haptics)
                    Toggle("回复逐字淡入", isOn: $fade)
                    Toggle("回复下显示耗时和用量", isOn: $stats)
                    Toggle("行迹默认展开", isOn: $traceOpen)
                    Toggle("聊天页的鲸鱼", isOn: $mascot)
                    Toggle("角落显示帧率", isOn: $fps)
                }

                Section {
                    Toggle("聊久了自动压缩前文", isOn: $autoCompress)
                    if autoCompress {
                        Stepper("超过 \(compressAt / 1000) 千字时压缩", value: $compressAt, in: 20_000...300_000, step: 10_000)
                    }
                    Stepper("压缩后留最近 \(keepRecent) 条原文", value: $keepRecent, in: 4...40, step: 2)
                } header: { Text("压缩") } footer: {
                    Text("压缩会让模型把较早的话写成一份前情提要，原文完整收进絮语页，随时能翻回去。也可以在聊天页的絮语页里手动压缩。")
                }

                Section {
                    Stepper("每次带上最近 \(contextChars / 1000) 千字", value: $contextChars, in: 8_000...400_000, step: 8_000)
                    Stepper(contextCount == 0 ? "条数不限" : "最多带 \(contextCount) 条", value: $contextCount, in: 0...200, step: 10)
                    Toggle("自己定温度", isOn: Binding(get: { temperature >= 0 }, set: { temperature = $0 ? 0.7 : -1 }))
                    if temperature >= 0 {
                        LabeledSlider(title: "温度", value: $temperature, range: 0...2, step: 0.1) { String(format: "%.1f", $0) }
                    }
                    Picker("最长回复", selection: $maxOutput) {
                        Text("模型默认").tag(0)
                        Text("2 千").tag(2048)
                        Text("4 千").tag(4096)
                        Text("8 千").tag(8192)
                        Text("1.6 万").tag(16384)
                        Text("3.2 万").tag(32768)
                    }
                } header: { Text("交给模型的") } footer: {
                    Text("带得越多，旅伴记得越多，但每次回复越慢、越费。温度高些更有想象力，低些更稳。最长回复的单位是 token。")
                }

                Section {
                    Toggle("每天一封晨信", isOn: $morningOn)
                    if morningOn {
                        Stepper("\(morningHour) 点以后第一次打开时写", value: $morningHour, in: 5...11)
                    }
                } header: { Text("晨信") } footer: {
                    Text("主旅伴会看看你的日程、提醒和天气，写一封短短的便笺。到点会提醒你一声，打开 Clio 就开始写。")
                }
                .onChange(of: morningOn) { _, _ in TeamModel.scheduleMorning() }

                Section {
                    Toggle("晚上写日记", isOn: $diaryOn)
                } header: { Text("旅伴的日常") } footer: {
                    Text("打开后，晚上九点以后你第一次离开 Clio 时，当天聊过的旅伴各写一页日记，三五句话，收在絮语页的日记本里，你可以回一句。每位旅伴一晚一次短请求，大约一两千 token。\n不花 token 的都一直开着：案头每天有潮水带来的小东西，攒进收藏册，隔几天来也不会错过；进一段絮语时，会告诉你别的絮语在你不在时做完了、出错了还是在等你批准。几天没来，谁也不会少什么。")
                }
                .onChange(of: morningHour) { _, _ in TeamModel.scheduleMorning() }

                Section {
                    Toggle("离开时干完活、出错都通知我", isOn: $notifyDone)
                    Toggle("锁屏和灵动岛显示旅伴在做什么", isOn: $liveOn)
                } header: { Text("在后台") } footer: {
                    Text("旅伴干活时，锁屏和灵动岛上有一张小卡片：谁在做、正在做什么、做了多久，要你批准时会亮一下，做完了留几分钟再消失。\n旅伴干活时你切走，iOS 会给一小段时间（通常半分钟左右）让它接着干。这期间干完了、出错了会发通知；要你批准时总会通知。时间快用完还没干完，会先把写到一半的存下来，回到 Clio 点「接着做」就从那里继续。点通知直接回到那段絮语。")
                }

                Section {
                    Button("全部恢复默认", role: .destructive) { reset() }
                }
            }
            }
            .paperForm()
            .navigationTitle("纸墨与絮语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .clioScheme(scheme)
    }

    /// 主色: the accent everything is drawn with.
    private var palettes: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text("主色")
            HStack(spacing: 0) {
                ForEach(Ink.palettes) { palette in
                    let picked = Theme.shared.key == palette.key
                    Button {
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { Theme.shared.pick(palette.key) }
                    } label: {
                        VStack(spacing: 4) {
                            Circle().fill(palette.accent).frame(width: 28, height: 28)
                                .padding(3)
                                .overlay(Circle().strokeBorder(picked ? palette.accent : Color.clear, lineWidth: 2))
                            Text(palette.title).font(.system(size: 12, weight: picked ? .semibold : .regular)).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("主色：\(palette.title)")
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    /// 桌面图标: the app's icon on the home screen.
    private var icons: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text("桌面图标")
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.m) {
                    ForEach(Self.iconChoices, id: \.preview) { item in
                        let picked = icon == item.name
                        Button {
                            Haptics.tick(0.5)
                            Task {
                                do {
                                    try await UIApplication.shared.setAlternateIconName(item.name)
                                    icon = item.name
                                    iconNote = nil
                                } catch {
                                    iconNote = "没换成：\(error.localizedDescription)"
                                }
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(item.preview)
                                    .resizable()
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked ? Ink.accent : Ink.rule, lineWidth: picked ? 2 : 1))
                                Text(item.title).font(.system(size: 12, weight: picked ? .semibold : .regular)).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("桌面图标：\(item.title)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            if let iconNote { Text(iconNote).font(Ink.footnote).foregroundStyle(Ink.stop) }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private func reset() {
        for key in ["look.scheme", "look.face", "look.size", "look.leading", "look.haptics", "look.fade", "look.stats", "look.traceOpen", "look.fps", "notify.done", "live.on", "look.accent",
                    "chat.autoCompress", "chat.compressAt", "chat.keepRecent", "chat.contextChars", "chat.contextCount", "chat.temperature", "chat.maxOutput"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        scheme = "system"; face = "song"; size = 17; leading = 8; haptics = true; fade = true; stats = true; traceOpen = false; fps = false; notifyDone = true
        autoCompress = true; compressAt = 60_000; keepRecent = 12; contextChars = 48_000; contextCount = 0; temperature = -1; maxOutput = 0
        liveOn = true
        Theme.shared.pick("dai")
        Haptics.thud()
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let shown: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(shown(value)).foregroundStyle(Ink.inkSoft).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

import AgentKit
import Craft
import SwiftUI
import UserNotifications
import UIKit

extension TeamModel {
    // MARK: Demo

    func showDemo() {
        phase = .demo
        bots = [
            BotInfo(id: "chief", name: "团子", role: "贴身助理", color: "orange", main: true, preview: "明早 8 点叫你起床，记得带伞哦", lastAt: Now.ms - 600_000),
            BotInfo(id: "scout", name: "小探", role: "查资料 · 逛网页", color: "magenta"),
            BotInfo(id: "writer", name: "墨墨", role: "写东西 · 改稿子", color: "violet"),
            BotInfo(id: "chef", name: "饭团", role: "吃什么 · 怎么做", color: "green"),
        ]
        settings.mainBotId = "chief"
        rooms = [RoomInfo(id: "trip", name: "周末去哪玩", preview: "小探：查到三个地方", members: ["chief", "scout"])]
        approvals = [
            Approval(id: "a1", botId: "chief", tool: "新建日程", reason: "周六 10:00  和朋友去磁器口", detail: .init(text: "提前 60 分钟提醒"), at: Now.ms, answerable: true),
            Approval(id: "a2", botId: "chef", tool: "添加提醒事项", reason: "今晚 18:30  泡黄豆", at: Now.ms, answerable: true),
        ]
        doing = [Self.key(bot: "scout"): "搜索：周末天气"]
        if Shots.name == "sidebar-past" {
            let key = Self.key(bot: "chief")
            pinned = [key]
            leafBook[key] = [
                Leaf(id: "shot-old-route", title: "周末路线和雨天备选", at: Now.ms - 86_400_000, count: 7),
                Leaf(id: "shot-old-list", title: "带给同行朋友的清单", at: Now.ms - 172_800_000, count: 4),
            ]
        }
    }

    func fillDemoError() {
        let key = Self.key(bot: "chief")
        let advice = Explain.model(ProviderError(status: 429, "slow down"), service: "演示服务")
        append(Entry(id: UUID().uuidString, at: Now.ms - 1_000, message: .user("帮我看看周末的天气。")), to: key)
        append(Entry(id: UUID().uuidString, at: Now.ms,
                     message: .assistant(advice.title + "\n" + advice.detail),
                     note: true, next: advice.next?.rawValue), to: key)
    }

    /// For screenshots: one conversation with every kind of thing a reply can hold (steps, sources, 心绪,
    /// thinking, a heading, a list, a table, code, files written), and a checklist under way.
    func fillDemoChat() {
        let key = Self.key(bot: "chief")
        guard history(key).isEmpty else { return }
        var at = Now.ms - 300_000
        func add(_ message: Message, label: String? = nil, pulse: String? = nil, tokens: Int? = nil) {
            at += 4_000
            var entry = Entry(id: UUID().uuidString, at: at, message: message, speaker: message.role == .user ? nil : "chief", photos: [], label: label)
            entry.pulse = pulse
            entry.tokens = tokens
            append(entry, to: key)
        }
        add(.user("这周六想带朋友在重庆转一天，帮我看看天气，排个不太累的路线"))
        let search = ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"重庆 周六 天气"}"#)
        add(.assistant("", toolCalls: [search], reasoning: "先查周六的天气，再按天气决定室内还是室外。"))
        add(.toolResult("周六 多云转小雨 14–19°C，下午 3 点后有雨。来源：https://www.weather.com.cn/weather/101040100.shtml", for: search), label: "搜索：重庆 周六 天气")
        let read = ToolCall(id: "c2", name: "web_read", arguments: #"{"url":"https://www.mafengwo.cn/travel-scenic-spot/mafengwo/10208.html"}"#)
        add(.assistant("", toolCalls: [read]))
        add(.toolResult("磁器口古镇……鹅岭二厂……重庆中国三峡博物馆…… https://www.mafengwo.cn/travel-scenic-spot/mafengwo/10208.html https://www.dianping.com/chongqing", for: read), label: "读网页：mafengwo.cn")
        let write = ToolCall(id: "c3", name: "write_file", arguments: #"{"path":"行程/周六.md"}"#)
        add(.assistant("", toolCalls: [write]))
        add(.toolResult("写好了：行程/周六.md", for: write), label: "书案：写 行程/周六.md")
        add(.assistant("""
        ## 周六路线：上午在外面，下午躲雨

        周六**多云转小雨**，下午三点后有雨，所以把要走路的放上午，下午进室内。

        1. **10:00 鹅岭二厂**：拍照的地方多，人还不挤
        2. **12:30 午饭**：附近的小面和豆花饭，吃完歇一会
        3. **14:30 三峡博物馆**：下雨也不怕，看完大概两小时

        | 时段 | 去哪 | 走路 |
        | :-- | :-- | --: |
        | 上午 | 鹅岭二厂 | 约 3 千步 |
        | 下午 | 三峡博物馆 | 约 4 千步 |

        记得带伞。路线我存进了 `行程/周六.md`，想改哪一段直接告诉我。
        """), pulse: "感受：想让这一天别被雨搅了\n回响：\n  - 上午的光适合拍照\n  - 博物馆比商场更像出来玩\n  - 豆花饭是重庆的底气\n读到：\n  - 朋友可能不常来重庆\n  - 「不太累」比「去得多」重要\n  - 也许想留点时间聊天\n想要：\n  - 把雨变成去博物馆的理由\n  - 让路线有余地", tokens: 2380)
        add(.user("再帮我把要带的东西列个清单"))
        setPlan(key, [
            PlanStep(text: "看一下周六下午的降雨时段", state: "done"),
            PlanStep(text: "按路线列出要带的东西", state: "doing"),
            PlanStep(text: "存进行程文件，加到提醒事项", state: "todo"),
        ])
    }

    func leaveDemo() {
        doing = [:]
        loading = true
        startup = Task.detached(priority: .userInitiated) { InitialData.read() }
        Task { await prepare() }
    }
}

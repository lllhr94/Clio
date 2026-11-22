import WidgetKit

/// Keeps the home-screen widget's snapshot fresh: the main companion, what it is doing, its last words.
@MainActor
enum WidgetFeed {
    private static var last: WidgetSnapshot?

    private static let toldKey = "widget.toldNoKeychain"

    static func publish(_ team: TeamModel) {
        guard let id = team.mainBotId, let bot = team.bots.first(where: { $0.id == id }) else { return }
        let key = TeamModel.key(bot: id)
        let kind: WidgetSnapshot.Kind
        let status: String
        if team.approvals.contains(where: { $0.chat == key }) {
            kind = .waiting
            status = L.t("pet.needsApproval")
        } else if team.isWorking(key) {
            kind = .working
            status = "正在干活"
        } else {
            kind = .idle
            status = L.t("chat.idle")
        }
        let cleanedLine = (bot.preview ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = WidgetSnapshot(
            name: bot.name,
            status: status,
            line: String(cleanedLine.prefix(120)),
            at: (bot.lastAt ?? 0) / 1000,
            chat: key,
            kind: kind,
            oled: Theme.shared.oled,
            plain: Theme.shared.plain
        )
        guard snapshot != last else { return }
        last = snapshot
        if Shelf.put(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        } else if !UserDefaults.standard.bool(forKey: Self.toldKey) {
            // The signing will not change by itself: say it once, not every time the widget is fed.
            UserDefaults.standard.set(true, forKey: Self.toldKey)
            Diag.note("小组件：这个签名不让 app 和小组件共用钥匙串，小组件拿不到近况（只记这一次）")
        }
    }
}

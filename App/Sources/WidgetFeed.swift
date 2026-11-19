import WidgetKit

/// Keeps the home-screen widget's snapshot fresh: the main companion, what it is doing, its last words.
@MainActor
enum WidgetFeed {
    private static var last: WidgetSnapshot?

    static func publish(_ team: TeamModel) {
        guard let id = team.mainBotId, let bot = team.bots.first(where: { $0.id == id }) else { return }
        let key = TeamModel.key(bot: id)
        let status = team.approvals.contains { $0.chat == key } ? "等你批准" : (team.isWorking(key) ? "在干活" : Words.t("闲坐"))
        let snapshot = WidgetSnapshot(name: bot.name, status: status, line: String((bot.preview ?? "").prefix(120)), at: (bot.lastAt ?? 0) / 1000, chat: key)
        guard snapshot != last else { return }
        last = snapshot
        if Shelf.put(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            Diag.note("小组件：这个签名不让 app 和小组件共用钥匙串，小组件拿不到近况")
        }
    }
}

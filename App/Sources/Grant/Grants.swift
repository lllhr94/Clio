import AgentKit
import Contacts
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import Photos
import SwiftUI
import UserNotifications

/// 应许: what companions may do, one ability at a time. Each is off, asks every time, or goes ahead.
enum Grant: String, CaseIterable, Identifiable, Sendable {
    case web, browser, desk, den, hills, mcp, google, vault, memory, letters, calendar, reminders, location, contacts, photos, motion, health, clipboard, links, device

    var id: String { rawValue }

    enum Policy: String, CaseIterable, Sendable {
        case off, ask, allow
        var title: String {
            switch self {
            case .off: "不许"
            case .ask: "每次问"
            case .allow: "放行"
            }
        }
    }

    /// As the user wants things named (poetic or plain).
    var title: String { Words.t(poeticTitle) }
    var note: String { Words.t(poeticNote) }

    private var poeticTitle: String {
        switch self {
        case .web: "寻访"
        case .browser: "远游"
        case .desk: "书案"
        case .den: "斗室"
        case .hills: "远山 · SSH"
        case .mcp: "远山 · MCP"
        case .google: "谷歌邮件与云盘"
        case .vault: "信匣"
        case .memory: "拾遗"
        case .letters: "来信"
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .location: "所在"
        case .contacts: "通讯录"
        case .photos: "相册"
        case .motion: "步数"
        case .health: "健康"
        case .clipboard: "剪贴板"
        case .links: "打开链接与 app"
        case .device: "手机状态"
        }
    }

    private var poeticNote: String {
        switch self {
        case .web: "联网搜索、读网页"
        case .browser: "在 app 里的浏览器打开、点击、填写网页"
        case .desk: "在书案里读写文件、跑 JS 计算"
        case .den: "在斗室的 Linux 里跑命令、装软件"
        case .hills: "用 SSH 在你的远程主机上跑命令"
        case .mcp: "用你接入的 MCP 服务提供的工具（含高德地图等连接器）"
        case .google: "找、读你的 Gmail 和云端硬盘，存邮件草稿；发信总会先问你"
        case .vault: "递笺请你填写、看信匣目录、从信匣取密码填网页（取用总会先问你）"
        case .memory: "记下或忘掉关于你的事"
        case .letters: "约好时间，到点给你发消息"
        case .calendar: "查看日程；新建日程总会先问你"
        case .reminders: "查看提醒；新建提醒总会先问你"
        case .location: "知道你现在大概在哪里"
        case .contacts: "按名字查通讯录里的人"
        case .photos: "看相册里最近的照片（时间、地点）"
        case .motion: "读手机记的步数和走过的距离"
        case .health: "读「健康」里的步数、睡眠、心率、活动能量和体重（只读，不写）"
        case .clipboard: "读或写剪贴板"
        case .links: "替你打开网址、地图、电话或其他 app"
        case .device: "电量、存储空间、系统版本"
        }
    }

    var symbol: String {
        switch self {
        case .web: "magnifyingglass"
        case .browser: "safari"
        case .desk: "books.vertical"
        case .den: "terminal"
        case .hills: "server.rack"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .google: "envelope.open"
        case .vault: "lock.rectangle.stack"
        case .memory: "bookmark"
        case .letters: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .location: "location"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .motion: "figure.walk"
        case .health: "heart"
        case .clipboard: "doc.on.clipboard"
        case .links: "arrow.up.forward.app"
        case .device: "iphone"
        }
    }

    /// Sensitive things ask first until the user says otherwise.
    var standard: Policy {
        switch self {
        case .location, .contacts, .photos, .clipboard, .links, .hills, .health, .google: .ask
        default: .allow
        }
    }

    var policy: Policy {
        get { UserDefaults.standard.string(forKey: "grant.\(rawValue)").flatMap(Policy.init(rawValue:)) ?? standard }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: "grant.\(rawValue)") }
    }

    /// Three ways to set everything at once. Each item can still be changed on its own afterwards.
    enum Preset: String, CaseIterable, Identifiable {
        case careful, standard, free

        var id: String { rawValue }

        var title: String {
            switch self {
            case .careful: "谨慎"
            case .standard: "平常"
            case .free: "放手"
            }
        }

        var line: String {
            switch self {
            case .careful: "读写、联网之外，样样先问"
            case .standard: "敏感的先问，其余直接做"
            case .free: Words.t("都直接做，只有信匣先问")
            }
        }

        func policy(for grant: Grant) -> Policy {
            switch self {
            case .standard: return grant.standard
            case .free: return grant == .vault ? .ask : .allow
            case .careful:
                switch grant {
                case .web, .desk, .memory, .device: return .allow
                default: return .ask
                }
            }
        }

        func apply() { for grant in Grant.allCases { grant.policy = policy(for: grant) } }

        /// The preset everything is set to now, if any.
        static var current: Preset? {
            allCases.first { preset in Grant.allCases.allSatisfy { $0.policy == preset.policy(for: $0) } }
        }
    }

    static func of(tool name: String) -> Grant? {
        switch name {
        case "web_search", "web_read", "weather": .web
        case "remember", "forget", "recall": .memory
        case "message_later", "schedule_task", "scheduled_tasks", "cancel_task": .letters
        case "calendar_events", "calendar_add": .calendar
        case "reminders", "reminder_add": .reminders
        case "shell": .den
        case "read_file", "write_file", "edit_file", "list_dir", "glob", "grep", "view_image", "photo_text", "read_pdf", "search_docs", "make_document", "generate_image": .desk
        case "ssh_run", "ssh_add_host": .hills
        case "ask_user", "vault_list", "browser_fill_secret": .vault
        case "where_am_i", "place_lookup": .location
        case "contacts_search", "contacts_add": .contacts
        case "photos_recent", "photos_save": .photos
        case "steps": .motion
        case "clipboard_read", "clipboard_write": .clipboard
        case "open_link": .links
        case "device_status": .device
        case "gmail_search", "gmail_read", "gmail_draft", "gmail_send", "drive_search", "drive_read": .google
        default:
            if name.hasPrefix("browser_") { .browser }
            else if name.hasPrefix("mcp_") { .mcp }
            else if name.hasPrefix("desk_") || name == "run_js" || name == "view_image" { .desk }
            else if name.hasPrefix("den_") { .den }
            else if name.hasPrefix("ssh_") || name.hasPrefix("hill_") { .hills }
            else if name.hasPrefix("health_") { .health }
            else { nil }
        }
    }

    /// Pure in-conversation orchestration tools that do not touch external services or user data directly.
    private static let internalTools: Set<String> = ["update_plan", "use_skill", "ask_companion"]

    /// The tools a companion gets: switched-off abilities left out, ask-first ones wrapped so they ask.
    /// `workspace` names the ability for the eight workspace tools, which depends on where the conversation works.
    static func gate(_ tools: [AgentTool], workspace: [String: Grant] = [:]) -> [AgentTool] {
        tools.compactMap { tool in
            let name = tool.spec.name
            guard let grant = workspace[name] ?? of(tool: name) else {
                if internalTools.contains(name) { return tool }
                return Asking(inner: tool, grant: nil)
            }
            switch grant.policy {
            case .off: return nil
            case .allow: return tool
            case .ask: return Asking(inner: tool, grant: grant)
            }
        }
    }

    // MARK: The system's side

    enum System: Equatable { case none, notAsked, granted, denied, limited }

    @MainActor
    var system: System {
        switch self {
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: return .notAsked
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            default: return .denied
            }
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .notDetermined: return .notAsked
            case .authorized: return .granted
            case .limited: return .limited
            default: return .denied
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .notDetermined: return .notAsked
            case .authorized: return .granted
            case .limited: return .limited
            default: return .denied
            }
        case .motion:
            switch CMPedometer.authorizationStatus() {
            case .notDetermined: return .notAsked
            case .authorized: return .granted
            default: return .denied
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .notDetermined: return .notAsked
            case .fullAccess, .writeOnly: return .granted
            default: return .denied
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .notDetermined: return .notAsked
            case .fullAccess: return .granted
            default: return .denied
            }
        case .health:
            // iOS never tells an app whether reading was allowed; only whether it has asked.
            guard Health.available else { return .denied }
            return Health.asked ? .granted : .notAsked
        default:
            return .none
        }
    }

    /// Shows the system's own question for this ability.
    @MainActor
    func requestSystem() async {
        switch self {
        case .location: _ = await Spot.shared.authorize()
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .motion: _ = await Phone.steps(days: 1)
        case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        case .letters: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .health: _ = await Health.authorize()
        default: break
        }
    }
}

/// A tool whose ability is set to ask: every call waits for the user's seal.
struct Asking: AgentTool {
    let inner: AgentTool
    let grant: Grant?

    var spec: ToolSpec { inner.spec }
    func label(for arguments: JSONValue) -> String { inner.label(for: arguments) }
    func approval(for arguments: JSONValue) -> ApprovalAsk? {
        let title = grant.map { "用\($0.title)" } ?? "用工具「\(inner.spec.name)」"
        return inner.approval(for: arguments) ?? ApprovalAsk(title: title, reason: inner.label(for: arguments))
    }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { try await inner.run(arguments) }
}

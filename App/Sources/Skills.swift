import AgentKit
import Craft
import SwiftUI

/// 技能: Markdown know-how in 书案/技能. Every conversation carries each skill's name and when to use it;
/// the companion reads the whole page with `use_skill` when a task matches.
enum SkillShelf {
    struct Item: Identifiable, Equatable, Sendable {
        /// The path in 书案.
        var id: String
        var skill: Skill
        var on: Bool
        var file: URL
    }

    static var folder: URL {
        let url = Workspace.root.appendingPathComponent("技能", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Paths of skills switched off.
    private static var off: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "skills.off") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "skills.off") }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, items: [Item])?
    nonisolated(unsafe) private static var cacheVersion = 0

    static func invalidate() {
        cacheLock.withLock {
            cache = nil
            cacheVersion += 1
        }
    }

    /// Every skill: `技能/名字.md`, or a folder `技能/名字/` holding SKILL.md (with anything else it needs beside it).
    static func all(fresh: Bool = false) -> [Item] {
        let (saved, version) = cacheLock.withLock { (cache, cacheVersion) }
        if !fresh, let saved, Date().timeIntervalSince(saved.at) < 5 { return saved.items }
        let manager = FileManager.default
        var items: [Item] = []
        let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let switchedOff = off
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard Workspace.isInsideRealRoot(entry, root: folder) else { continue }
            var file = entry
            var fallback = entry.deletingPathExtension().lastPathComponent
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard let inner = ["SKILL.md", "skill.md", "技能.md", "README.md"].map({ entry.appendingPathComponent($0) }).first(where: { manager.fileExists(atPath: $0.path) }) else { continue }
                file = inner
                fallback = entry.lastPathComponent
            } else if !["md", "markdown", "txt"].contains(entry.pathExtension.lowercased()) {
                continue
            }
            guard Workspace.isInsideRealRoot(file, root: folder),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let path = Workspace.relative(file)
            items.append(Item(id: path, skill: Skill.parse(text, fallback: fallback), on: !switchedOff.contains(path), file: file))
        }
        cacheLock.withLock { if version == cacheVersion { cache = (Date(), items) } }
        return items
    }

    static var enabled: [Item] { all().filter(\.on) }

    static func setOn(_ item: Item, _ on: Bool) {
        cacheLock.withLock {
            var set = off
            if on { set.remove(item.id) } else { set.insert(item.id) }
            off = set
            if var current = cache {
                for index in current.items.indices where current.items[index].id == item.id {
                    current.items[index].on = on
                }
                cache = (Date(), current.items)
            }
            cacheVersion += 1
        }
    }

    /// Writes a skill: over its own file, or as a new 技能/名字.md.
    @discardableResult
    static func save(_ skill: Skill, over file: URL?) -> URL {
        let baseName = safe(skill.name)
        var target = file ?? folder.appendingPathComponent(baseName + ".md")
        if file == nil {
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(baseName) \(number).md")
                number += 1
            }
        }
        try? Data(skill.text.utf8).write(to: target, options: .atomic)
        invalidate()
        return target
    }

    static func remove(_ item: Item) {
        let parent = item.file.deletingLastPathComponent()
        // A skill kept as a folder goes with its folder.
        let target = parent.standardizedFileURL == folder.standardizedFileURL ? item.file : parent
        guard Workspace.isInsideRealRoot(target, root: folder),
              target.standardizedFileURL.path != folder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: target)
        invalidate()
    }

    static func safe(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        var cleaned = name
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while let last = cleaned.last, last == "." || last.isWhitespace {
            cleaned.removeLast()
        }
        cleaned = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, last == "." || last.isWhitespace {
            cleaned.removeLast()
        }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "技能"
        }
        return cleaned
    }

    /// The lines for the system prompt; empty without skills.
    static var promptBlock: String {
        let skills = enabled.map(\.skill)
        guard !skills.isEmpty else { return "" }
        return "\n\n你会的技能（书案/技能 里的说明，用户可以自己加）：\n" + Skill.menu(skills) + "\n任务和某个技能对得上时，先用 use_skill 读它的全文，再照着做。"
    }

    /// A few to start from. Written for Clio; change them to taste.
    static let samples: [Skill] = [
        Skill(name: "旅行规划", description: "用户要安排出行（周末游、出差、长假）时用：先问清楚，再排行程、算预算", body: """
        # 旅行规划

        1. 先问清楚（已经说过的不再问）：从哪出发、去哪、几天、几个人、预算、想玩什么、有没有不能吃的。
        2. 查实时信息：天气、交通（高铁/航班大致时间和价格）、景点开放时间和要不要预约。用 web_search，再 web_read 核实。
        3. 排行程：按天分，每天上午、下午、晚上各一两件事，同一片区域的放一起，别太赶。写清楚怎么过去、大概多久。
        4. 算预算：交通、住宿、门票、吃饭分开列，给一个总数和浮动范围。
        5. 最后列出发前要做的事（订票、预约、带的东西）。用户同意的话，用 calendar_add 把出发和返程放进日历，把清单存进书案/旅行/目的地.md。

        口吻轻松，像朋友帮忙安排。不确定的信息要说不确定。
        """),
        Skill(name: "周报", description: "用户要写周报、月报、工作总结时用：整理这段时间做的事，按固定格式写", body: """
        # 周报

        - 材料：先问用户这周做了什么；也可以看看书案里这周改过的文件（glob、grep）、日历里这周的日程（calendar_events）。
        - 格式：
          ## 本周完成
          - 每条一句：做了什么，结果是什么（有数字写数字）
          ## 进行中
          - 做到哪了，卡在哪
          ## 下周计划
          - 三到五条
          ## 需要协调
          - 没有就写「无」
        - 语气平实，不夸大，不写空话。写完存到书案/周报/年份-第几周.md，告诉用户路径。
        """),
        Skill(name: "读长文档", description: "用户要你读论文、合同、说明书、报告这类长文档并回答问题时用：先找后读，标出处", body: """
        # 读长文档

        1. 文件在书案里：先 search_docs 用两三个关键词找到相关的页，再用 read_pdf（PDF）或 read_file 细读那几页，不要从头到尾读。
        2. 是网址：web_read 能直接读 PDF，长的用 page 参数分段读。
        3. 回答时先给结论，再给依据，每条依据写清楚出自哪个文件第几页。
        4. 原文没写的，直接说没写，不要猜。
        5. 合同类：特别留意金额、期限、违约责任、自动续约、解约条件，单独列出来提醒用户。
        """),
        Skill(name: "记账", description: "用户说花了钱、收了钱，或者要看开销时用：记进书案/账本.csv，按月汇总", body: """
        # 记账

        - 账本：书案/账本.csv，表头是「日期,类别,金额,备注」。金额支出写负数，收入写正数。没有就新建。
        - 记一笔：从用户的话里拿日期（没说就是今天）、金额、类别（餐饮、交通、购物、住房、娱乐、医疗、学习、其他），用 run_js 读出账本、加一行、写回去。记完说一句「记好了：……」。
        - 看开销：用 run_js 按月、按类别汇总，给出总支出、最多的三个类别、和上个月比多了还是少了。
        - 不要把账本内容记进拾遗。
        """),
    ]

    /// Puts the samples in, leaving any with the same name alone. Returns how many were added.
    @discardableResult
    static func installSamples() -> Int {
        let names = Set(all(fresh: true).map(\.skill.name))
        var added = 0
        for skill in samples where !names.contains(skill.name) {
            save(skill, over: nil)
            added += 1
        }
        return added
    }
}

/// Reads a skill's whole page.
struct UseSkillTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "use_skill", description: "读一个技能的全文（技能列在你的设定里）。任务和某个技能对得上时先读，再照着做。", parameters: [
            "type": "object",
            "properties": ["name": ["type": "string", "description": "技能名字"]],
            "required": ["name"],
        ])
    }

    func label(for arguments: JSONValue) -> String { "翻技能：\(arguments["name"]?.string ?? "")" }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let wanted = arguments["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items = SkillShelf.enabled
        let matched: SkillShelf.Item?
        if wanted.isEmpty {
            matched = nil
        } else {
            matched = items.first(where: { $0.skill.name == wanted })
                ?? items.first(where: { $0.skill.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame })
                ?? items.first(where: { $0.skill.name.localizedCaseInsensitiveContains(wanted) || wanted.localizedCaseInsensitiveContains($0.skill.name) })
        }
        guard let item = matched else {
            return ToolOutput("没有叫「\(wanted)」的技能。有的是：" + items.map(\.skill.name).joined(separator: "、"), isError: true)
        }
        var text = "技能「\(item.skill.name)」（\(item.id)）：\n\n\(item.skill.body)"
        let parent = item.file.deletingLastPathComponent()
        if parent.standardizedFileURL != SkillShelf.folder.standardizedFileURL {
            let parentPath = parent.standardizedFileURL.path
            var others: [String] = []
            if let walker = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in walker {
                    guard Workspace.isInsideRealRoot(url, root: parent),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let std = url.standardizedFileURL.path
                    guard std != item.file.standardizedFileURL.path, std.hasPrefix(parentPath + "/") else { continue }
                    others.append(String(std.dropFirst(parentPath.count + 1)))
                    if others.count >= 40 { break }
                }
            }
            if !others.isEmpty {
                text += "\n\n这个技能的文件夹（书案/\(Workspace.relative(parent))）里还有：" + others.sorted().joined(separator: "、") + "。需要时用 read_file 读。"
            }
        }
        return ToolOutput(text)
    }
}

// MARK: Page

/// 技能: what the companions know how to do, each a page the user can read, change, switch off or add.
struct SkillsPage: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SkillShelf.Item] = []
    @State private var loading = true
    @State private var scan = 0
    @State private var editing: Editing?
    @State private var installing = false
    @State private var note: String?

    struct Editing: Identifiable {
        var id = UUID()
        var item: SkillShelf.Item?
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .hitchPage("技能")
        .task(id: scan) {
            let found = await Task.detached(priority: .utility) { SkillShelf.all(fresh: true) }.value
            guard !Task.isCancelled else { return }
            items = found
            loading = false
        }
        .sheet(item: $editing, onDismiss: reload) { editing in
            SkillEditor(item: editing.item)
        }
        .sheet(isPresented: $installing) {
            SkillInstallSheet { installedName in
                note = "装好了「\(installedName)」。"
                reload()
            }
        }
    }

    private var content: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.l) {
                    Text(Words.t("书案/技能 里的做事说明，对得上就照做"))
                        .font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                    if loading {
                        ProgressView(L.t("loading.generic"))
                    } else if items.isEmpty {
                        VStack(alignment: .leading, spacing: Ink.Space.m) {
                            EmptyNote(symbol: "books.vertical", words: L.t("empty.skills"))
                            Button("从链接 / zip 安装技能") {
                                installing = true
                            }
                            .font(.system(size: Ink.Size.sub, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            Button("装几个示例：旅行规划、周报、读长文档、记账") {
                                installSamples()
                            }
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(Ink.inkSoft)
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                row(item)
                                if item.id != items.last?.id { Kit.divider }
                            }
                        }
                        .paperCard()
                    }
                    if let note { Text(note).font(Ink.footnote).foregroundStyle(Ink.inkSoft) }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("agent.skills"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("从链接 / zip 安装", systemImage: "square.and.arrow.down.on.square") { installing = true }
                        Button("写一个新技能", systemImage: "square.and.pencil") { editing = Editing(item: nil) }
                        Button("装示例技能", systemImage: "tray.and.arrow.down") {
                            installSamples(fromMenu: true)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添技能")
                }
            }
    }

    private func reload() { scan += 1 }

    private func installSamples(fromMenu: Bool = false) {
        Task {
            let count = await Task.detached(priority: .utility) { SkillShelf.installSamples() }.value
            note = fromMenu ? (count > 0 ? "装好 \(count) 个示例。" : "示例都已经在了。") : "装好 \(count) 个，点开可以改成你的习惯。"
            reload()
            if !fromMenu { Haptics.thud() }
        }
    }

    private func row(_ item: SkillShelf.Item) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(item.skill.name).font(.system(size: Ink.Size.body, weight: .semibold)).foregroundStyle(item.on ? Ink.ink : Ink.inkFaint)
                Text(item.skill.description).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(2)
                Text(Words.t("书案/") + item.id).font(Ink.mono(Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { item.on }, set: { value in
                SkillShelf.setOn(item, value)
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].on = value }
            }))
            .labelsHidden()
            .tint(Ink.accent)
        }
        .padding(Ink.Space.l)
        .contentShape(Rectangle())
        .onTapGesture { editing = Editing(item: item) }
        .contextMenu {
            Button("改一改", systemImage: "pencil") { editing = Editing(item: item) }
            Button("删掉", systemImage: "trash", role: .destructive) {
                let target = item
                Task {
                    await Task.detached(priority: .userInitiated) { SkillShelf.remove(target) }.value
                    items.removeAll { $0.id == target.id }
                }
            }
        }
    }
}

/// Writing or changing one skill.
struct SkillEditor: View {
    let item: SkillShelf.Item?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var body_ = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L.t("skills.name")) {
                    TextField("比如：周报", text: $name)
                }
                Section {
                    TextField("比如：用户要写周报时用", text: $description, axis: .vertical).lineLimit(1...3)
                } header: {
                    Text("什么时候用")
                } footer: {
                    Text("写清楚是哪类事")
                }
                Section {
                    TextEditor(text: $body_)
                        .font(.system(size: Ink.Size.sub))
                        .frame(minHeight: 260)
                } header: {
                    Text("怎么做")
                } footer: {
                    Text("Markdown：步骤、格式、注意事项")
                }
            }
            .paperForm()
            .scrollContentBackground(.hidden)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(item == nil ? L.t("skills.new") : L.t("skills.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) {
                        guard !saving else { return }
                        saving = true
                        let skill = Skill(name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description.trimmingCharacters(in: .whitespacesAndNewlines), body: body_.trimmingCharacters(in: .whitespacesAndNewlines))
                        let file = item?.file
                        Task {
                            await Task.detached(priority: .userInitiated) {
                                SkillShelf.save(skill, over: file)
                            }.value
                            Haptics.thud()
                            dismiss()
                        }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || body_.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            guard let item else { return }
            name = item.skill.name
            description = item.skill.description
            body_ = item.skill.body
        }
    }
}

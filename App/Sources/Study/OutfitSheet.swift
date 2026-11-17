import SwiftUI

/// 装常用软件: pick a mirror and the tools, get one command to run in 斗室.
struct OutfitSheet: View {
    let done: (String?) -> Void

    private static let mirrors: [(String, String)] = [
        ("清华", "mirrors.tuna.tsinghua.edu.cn"),
        ("中科大", "mirrors.ustc.edu.cn"),
        ("阿里云", "mirrors.aliyun.com"),
        ("官方", "dl-cdn.alpinelinux.org"),
    ]
    private static let kits: [(String, String, String)] = [
        ("Python", "python3 py3-pip", "跑脚本、处理数据"),
        ("Node.js", "nodejs npm", "跑 JavaScript 工具"),
        ("Git", "git", "拉代码"),
        ("OpenSSH", "openssh-client", "从斗室连别的主机"),
        ("常用小工具", "bash coreutils curl wget jq less file tree", "bash、curl、jq 等"),
        ("编辑器", "vim nano", "在笔砚里改文件"),
    ]

    @State private var mirror = "mirrors.tuna.tsinghua.edu.cn"
    @State private var chosen: Set<String> = ["Python", "常用小工具"]

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                Section {
                    Picker("软件源", selection: $mirror) {
                        ForEach(Self.mirrors, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("软件源") } footer: { Text("国内用清华或中科大会快很多。") }
                Section("要装的") {
                    ForEach(Self.kits, id: \.0) { kit in
                        Button {
                            if chosen.contains(kit.0) { chosen.remove(kit.0) } else { chosen.insert(kit.0) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kit.0).foregroundStyle(Ink.ink)
                                    Text(kit.2).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(kit.0) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(kit.0) ? Ink.accent : Ink.inkFaint)
                            }
                        }
                    }
                }
            }
            }
            .paperForm()
            .navigationTitle("装常用软件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { done(nil) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开装") { done(command) }.fontWeight(.semibold).disabled(chosen.isEmpty && mirror == "dl-cdn.alpinelinux.org")
                }
            }
        }
    }

    private var command: String {
        let packages = Self.kits.filter { chosen.contains($0.0) }.map(\.1).joined(separator: " ")
        let source = "sed -i 's#https\\?://[^/]*/alpine#https://\(mirror)/alpine#g' /etc/apk/repositories && apk update"
        return packages.isEmpty ? source : source + " && apk add \(packages)"
    }
}

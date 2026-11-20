import CoreText
import SwiftUI

/// Apple's own 宋体 and 楷体 are not on a phone until asked for: this fetches them once, with progress,
/// and asks for them again at launch so a picked one is there (a quick look-up once fetched).
@MainActor
@Observable
final class FontShelf {
    static let shared = FontShelf()

    enum State: Equatable { case ready, missing, loading(Double), failed }

    private var loading: [Pref.Face: Double] = [:]
    private var failed: Set<Pref.Face> = []
    /// Bumped when a fetch ends, so whatever reads a face draws again.
    private(set) var generation = 0

    func state(_ face: Pref.Face) -> State {
        _ = generation
        guard face.downloads, let name = face.postScript(bold: false) else { return .ready }
        if Ink.has(name) { return .ready }
        if let progress = loading[face] { return .loading(progress) }
        return failed.contains(face) ? .failed : .missing
    }

    /// At launch: the faces in use, if Apple's, made ready again.
    func prepare() {
        for face in Set([Pref.face, Pref.mark]) where face.downloads { fetch(face) }
    }

    func fetch(_ face: Pref.Face) {
        guard face.downloads, loading[face] == nil, state(face) != .ready else { return }
        let names = [face.postScript(bold: false), face.postScript(bold: true)].compactMap { $0 }
        let descriptors = names.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) } as CFArray
        loading[face] = 0
        failed.remove(face)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors, nil) { state, info in
            let values = info as NSDictionary
            let percent = (values[kCTFontDescriptorMatchingPercentage] as? Double) ?? 0
            Task { @MainActor in
                let shelf = FontShelf.shared
                switch state {
                case .downloading:
                    shelf.loading[face] = percent / 100
                case .didFailWithError:
                    shelf.loading[face] = nil
                    shelf.failed.insert(face)
                    shelf.generation += 1
                case .didFinish:
                    shelf.loading[face] = nil
                    if !Ink.has(names[0]) { shelf.failed.insert(face) }
                    shelf.generation += 1
                default:
                    break
                }
            }
            return true
        }
    }
}

/// 字体: what the conversation reads in, and what titles and inscriptions are written in. Each face is shown in itself.
struct FontPage: View {
    @State private var shelf = FontShelf.shared

    var body: some View {
        Form {
            PaperRows {
                Section {
                    ForEach(Pref.Face.allCases) { face in
                        row(face, picked: Pref.face == face, sample: "纸墨之间，自有清欢。Clio 0.33") {
                            Theme.shared.setFace(face)
                        }
                    }
                } header: { Text("正文") } footer: {
                    Text("对话、笔记这类要读的文字。字号在「外观」里调。")
                }

                Section {
                    Inscription(text: L.t("empty.inscription"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Ink.Space.s)
                    ForEach(Pref.Face.marks) { face in
                        row(face, picked: Pref.mark == face, sample: "往日历里加一个日程") {
                            Theme.shared.setMark(face)
                        }
                    }
                } header: { Text("标题和题词") } footer: {
                    Text("空对话上的那句话、引导页和批准单的标题。按钮和正文不跟着变。")
                }

                Section {
                    ForEach(Pref.Code.allCases) { code in
                        codeRow(code)
                    }
                } header: { Text("代码") } footer: {
                    Text("回复里的代码、终端、步骤里的命令、模型名。中文仍用正文字体。")
                }

                Section {
                    Text("文楷取自霞鹜文楷 GB 1.530（按国家标准字形修订的版本），朱印取自马善政毛笔楷书，代码字体是 Maple Mono 7.9，都是开源字体（SIL OFL 1.1），为了装进 App 只留了简体常用字，改名 Clio Kai、Clio Seal。宋体、楷体由苹果提供。")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                } header: { Text("出处") }
            }
        }
        .paperForm()
        .navigationTitle("字体")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ face: Pref.Face, picked: Bool, sample: String, choose: @escaping () -> Void) -> some View {
        let state = shelf.state(face)
        return Button {
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) { choose() }
            if state != .ready { shelf.fetch(face) }
        } label: {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(spacing: Ink.Space.s) {
                        Text(face.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink)
                        Text(face.note).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                    }
                    Text(sample)
                        .font(Ink.face(face, (19 * UIScale.factor).rounded()))
                        .foregroundStyle(state == .ready ? Ink.ink : Ink.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: Ink.Space.s)
                trailing(state, picked: picked)
            }
            .padding(.vertical, Ink.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(face.title)，\(face.note)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func codeRow(_ code: Pref.Code) -> some View {
        let picked = Pref.code == code
        return Button {
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) { Theme.shared.setCode(code) }
        } label: {
            HStack(alignment: .center, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    HStack(spacing: Ink.Space.s) {
                        Text(code.title).font(.system(size: Ink.Size.body, weight: .medium)).foregroundStyle(Ink.ink)
                        Text(code.note).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                    }
                    Text("git log --oneline -3  # 0.33")
                        .font(Ink.mono(Ink.Size.sub, preference: code))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: Ink.Space.s)
                if picked {
                    Image(systemName: "checkmark").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent)
                }
            }
            .padding(.vertical, Ink.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(code.title)，\(code.note)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private func trailing(_ state: FontShelf.State, picked: Bool) -> some View {
        switch state {
        case .loading(let progress):
            ProgressView(value: progress).frame(width: 44)
        case .missing:
            Text("下载").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.accent)
        case .failed:
            Text("重试").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.stop)
        case .ready:
            if picked {
                Image(systemName: "checkmark").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.accent)
            }
        }
    }
}

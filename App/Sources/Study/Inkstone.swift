import SwiftTerm
import SwiftUI
import UIKit

/// 笔砚: a real terminal on 斗室 — vim, top, python's prompt all work. The key row has Esc, Tab, Ctrl and arrows.
struct InkstonePage: View {
    @ObservedObject private var den = Den.shared
    @Environment(\.dismiss) private var dismiss
    @State private var session = 0
    @State private var ended = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ink.Space.m) {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(PressStyle())
                VStack(alignment: .leading, spacing: 0) {
                    Text("笔砚").font(Ink.serif(19, bold: true)).foregroundStyle(Ink.ink)
                    Text(ended ? "shell 已经结束" : "斗室 · Alpine Linux").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                }
                Spacer()
                if ended {
                    Button("再开一个") {
                        ended = false
                        session += 1
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.s)

            switch den.state {
            case .awake:
                TerminalHost(ended: $ended)
                    .id(session)
                    .padding(.horizontal, 4)
            case .broken(let why):
                Text(why).font(Ink.secondary).foregroundStyle(Ink.stop).frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                VStack(spacing: Ink.Space.m) {
                    ProgressView()
                    Text(den.state == .unpacking ? "第一次打开，正在铺陈" : "正在醒来").font(Ink.secondary).foregroundStyle(Ink.inkSoft)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .task { _ = await den.wake() }
    }
}

private struct TerminalHost: UIViewRepresentable {
    @Binding var ended: Bool
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(ended: $ended) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        paint(view)
        context.coordinator.attach(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        paint(view)
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.shell?.close()
    }

    private func paint(_ view: TerminalView) {
        let dark = scheme == .dark
        view.nativeBackgroundColor = dark ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) : UIColor(red: 0.985, green: 0.97, blue: 0.94, alpha: 1)
        view.nativeForegroundColor = dark ? UIColor(red: 0.92, green: 0.89, blue: 0.84, alpha: 1) : UIColor(red: 0.17, green: 0.16, blue: 0.14, alpha: 1)
        view.caretColor = UIColor(red: 0.29, green: 0.42, blue: 0.54, alpha: 1)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        @Binding var ended: Bool
        var shell: DenTerminal?
        weak var view: TerminalView?

        init(ended: Binding<Bool>) { _ended = ended }

        func attach(_ view: TerminalView) {
            self.view = view
            var error: Int32 = 0
            shell = DenTerminal.open(output: { [weak view] data in
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            }, exited: { [weak self] in
                self?.ended = true
            }, error: &error)
            if shell == nil {
                view.feed(text: "笔砚没能打开（错误 \(error)）\r\n")
            } else {
                let terminal = view.getTerminal()
                shell?.resize(columns: Int32(terminal.cols), rows: Int32(terminal.rows))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            shell?.resize(columns: Int32(newCols), rows: Int32(newRows))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            shell?.send(Data(data))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) { Haptics.tick(0.4) }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

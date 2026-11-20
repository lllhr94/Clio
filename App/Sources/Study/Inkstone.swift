import Citadel
import NIOCore
import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit

/// 笔砚: a real terminal — on 斗室, or on one of 远山's computers over SSH. vim, top, python's prompt all work.
/// The key row has Esc, Tab, Ctrl and arrows.
struct InkstonePage: View {
    /// Nil: 斗室.
    @State private var hill: Hills.Host?

    init(hill: Hills.Host? = nil) { _hill = State(initialValue: hill) }
    @ObservedObject private var den = Den.shared
    @ObservedObject private var hills = Hills.shared
    @Environment(\.dismiss) private var dismiss
    @State private var session = 0
    @State private var ended = false
    @State private var endedWhy: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ink.Space.m) {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 36, height: 36)
                        .glassFace(in: Circle())
                }
                .buttonStyle(PressStyle())
                Menu {
                    Section("在哪台机器上写") {
                        Button {
                            switchTo(nil)
                        } label: {
                            if hill == nil { Label(Words.t("斗室 · 手机里"), systemImage: "checkmark") } else { Text(Words.t("斗室 · 手机里")) }
                        }
                        ForEach(hills.hosts) { host in
                            Button {
                                switchTo(host)
                            } label: {
                                if hill?.id == host.id { Label(Words.t("远山 · \(host.name)"), systemImage: "checkmark") } else { Text(Words.t("远山 · \(host.name)")) }
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text("笔砚").font(Ink.serif(19, bold: true)).foregroundStyle(Ink.ink)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                        Text(subtitle).font(Ink.footnote).foregroundStyle(ended ? Ink.stop : Ink.inkSoft).lineLimit(1)
                    }
                }
                .accessibilityLabel("笔砚：换一台机器")
                Spacer()
                if ended {
                    Button(hill == nil ? "再开一个" : "重新连") {
                        ended = false
                        endedWhy = nil
                        session += 1
                    }
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.s)

            if let hill {
                TerminalHost(ended: $ended, why: $endedWhy, hill: hill)
                    .id(session)
                    .padding(.horizontal, 4)
            } else {
                switch den.state {
                case .awake:
                    TerminalHost(ended: $ended, why: $endedWhy, hill: nil)
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
        }
        .background(Ink.paper.ignoresSafeArea())
        .task(id: hill?.id) { if hill == nil { _ = await den.wake() } }
        .hitchPage("笔砚")
    }

    private func switchTo(_ host: Hills.Host?) {
        Haptics.tick(0.5)
        guard host?.id != hill?.id else { return }
        hill = host
        ended = false
        endedWhy = nil
        session += 1
    }

    private var subtitle: String {
        if let hill {
            if ended { return endedWhy.map { "断开了：\($0)" } ?? "连接已经结束" }
            return Words.t("远山 · \(hill.user)@\(hill.address)")
        }
        return ended ? "shell 已经结束" : Words.t("斗室 · Alpine Linux")
    }
}

private struct TerminalHost: UIViewRepresentable {
    @Binding var ended: Bool
    @Binding var why: String?
    let hill: Hills.Host?
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(ended: $ended, why: $why, hill: hill) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.terminalDelegate = context.coordinator
        view.font = Ink.uiMono(13)
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
        coordinator.far?.close()
    }

    private func paint(_ view: TerminalView) {
        let dark = scheme == .dark
        view.nativeBackgroundColor = dark ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) : UIColor(red: 0.985, green: 0.97, blue: 0.94, alpha: 1)
        view.nativeForegroundColor = dark ? UIColor(red: 0.92, green: 0.89, blue: 0.84, alpha: 1) : UIColor(red: 0.17, green: 0.16, blue: 0.14, alpha: 1)
        view.caretColor = UIColor(red: 0.29, green: 0.42, blue: 0.54, alpha: 1)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        @Binding var ended: Bool
        @Binding var why: String?
        let hill: Hills.Host?
        var shell: DenTerminal?
        var far: HillShell?
        weak var view: TerminalView?

        init(ended: Binding<Bool>, why: Binding<String?>, hill: Hills.Host?) {
            _ended = ended
            _why = why
            self.hill = hill
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let terminal = view.getTerminal()
            if let hill {
                view.feed(text: "正在连 \(hill.name)（\(hill.user)@\(hill.address)）…\r\n")
                let far = HillShell()
                self.far = far
                far.start(hill, columns: terminal.cols, rows: terminal.rows, output: { [weak view] data in
                    DispatchQueue.main.async { view?.feed(byteArray: ArraySlice([UInt8](data))) }
                }, ended: { [weak self] problem in
                    DispatchQueue.main.async {
                        self?.why = problem
                        self?.ended = true
                        if let problem { self?.view?.feed(text: "\r\n\u{1B}[31m\(problem)\u{1B}[0m\r\n") }
                    }
                })
                return
            }
            var error: Int32 = 0
            shell = DenTerminal.open(output: { [weak view] data in
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            }, exited: { [weak self] in
                self?.ended = true
            }, error: &error)
            if shell == nil {
                view.feed(text: "笔砚没能打开（错误 \(error)）\r\n")
            } else {
                shell?.resize(columns: Int32(terminal.cols), rows: Int32(terminal.rows))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            shell?.resize(columns: Int32(newCols), rows: Int32(newRows))
            far?.resize(columns: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            shell?.send(Data(data))
            far?.send(Data(data))
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

/// An interactive shell on a 远山 host: its own SSH connection with a pseudo-terminal.
/// Keys and size changes go through one queue, so they arrive in the order they were typed.
final class HillShell: @unchecked Sendable {
    private enum Event {
        case bytes(Data)
        case size(Int, Int)
    }

    private var task: Task<Void, Never>?
    private let events: AsyncStream<Event>
    private let feed: AsyncStream<Event>.Continuation

    init() {
        let pair = AsyncStream<Event>.makeStream()
        events = pair.stream
        feed = pair.continuation
    }

    func start(_ host: Hills.Host, columns: Int, rows: Int, output: @escaping @Sendable (Data) -> Void, ended: @escaping @Sendable (String?) -> Void) {
        let events = events
        task = Task.detached {
            do {
                let client = try await Hills.connect(host)
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: max(20, columns),
                    terminalRowHeight: max(5, rows),
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                try await client.withPTY(request, environment: []) { inbound, outbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await event in events {
                                switch event {
                                case .bytes(let data):
                                    try await outbound.write(ByteBuffer(bytes: data))
                                case .size(let columns, let rows):
                                    try await outbound.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        }
                        group.addTask {
                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let buffer), .stderr(let buffer):
                                    output(Data(buffer.readableBytesView))
                                }
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
                try? await client.close()
                ended(nil)
            } catch is CancellationError {
                ended(nil)
            } catch let failed as SSHClient.CommandFailed {
                ended(failed.exitCode == 0 ? nil : "退出码 \(failed.exitCode)")
            } catch {
                ended(error.localizedDescription)
            }
        }
    }

    func send(_ data: Data) { feed.yield(.bytes(data)) }

    func resize(columns: Int, rows: Int) { feed.yield(.size(columns, rows)) }

    func close() {
        feed.finish()
        task?.cancel()
    }
}

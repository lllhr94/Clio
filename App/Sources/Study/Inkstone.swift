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
                        HStack(spacing: Ink.Space.xs) {
                            Text(L.t("nav.terminal")).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                        Text(subtitle).font(Ink.footnote).foregroundStyle(ended ? Ink.stop : Ink.inkSoft).lineLimit(1)
                    }
                }
                .accessibilityLabel(L.t("nav.terminal") + "：换一台机器")
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
                Button(L.t("actions.done")) {
                    Haptics.light()
                    dismiss()
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.s)

            if let hill {
                TerminalHost(ended: $ended, why: $endedWhy, hill: hill)
                    .id(session)
                    .padding(.horizontal, Ink.Space.xs)
            } else {
                switch den.state {
                case .awake:
                    TerminalHost(ended: $ended, why: $endedWhy, hill: nil)
                        .id(session)
                        .padding(.horizontal, Ink.Space.xs)
                case .broken(let why):
                    Text(why).font(Ink.secondary).foregroundStyle(Ink.stop).frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    VStack(spacing: Ink.Space.m) {
                        ProgressView()
                        Text(den.state == .unpacking ? "第一次打开，正在准备（要一会儿）" : "正在启动").font(Ink.secondary).foregroundStyle(Ink.inkSoft)
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
        view.font = Ink.uiMono(Ink.Size.small)
        paint(view)
        context.coordinator.appliedColorScheme = scheme
        context.coordinator.attach(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        let font = Ink.uiMono(Ink.Size.small)
        if view.font != font { view.font = font }
        if context.coordinator.appliedColorScheme != scheme {
            paint(view)
            context.coordinator.appliedColorScheme = scheme
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.shutdown()
    }

    private func paint(_ view: TerminalView) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = UIColor(Ink.paper).resolvedColor(with: traits)
        view.nativeForegroundColor = UIColor(Ink.ink).resolvedColor(with: traits)
        view.caretColor = UIColor(Ink.accent).resolvedColor(with: traits)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        @Binding var ended: Bool
        @Binding var why: String?
        let hill: Hills.Host?
        var shell: DenTerminal?
        var far: HillShell?
        weak var view: TerminalView?
        var appliedColorScheme: ColorScheme?
        private var outputBuffer: OutputBuffer?

        init(ended: Binding<Bool>, why: Binding<String?>, hill: Hills.Host?) {
            _ended = ended
            _why = why
            self.hill = hill
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let buffer = OutputBuffer { [weak view] chunk in
                view?.feed(byteArray: chunk[...])
            }
            self.outputBuffer = buffer
            let terminal = view.getTerminal()
            if let hill {
                view.feed(text: "正在连 \(hill.name)（\(hill.user)@\(hill.address)）…\r\n")
                let far = HillShell()
                self.far = far
                far.start(hill, columns: terminal.cols, rows: terminal.rows, output: { data in
                    buffer.append(data)
                }, ended: { [weak self] problem in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.outputBuffer?.flush()
                            self?.why = problem
                            self?.ended = true
                            if let problem { self?.view?.feed(text: "\r\n\u{1B}[31m\(problem)\u{1B}[0m\r\n") }
                        }
                    }
                })
                return
            }
            var error: Int32 = 0
            shell = DenTerminal.open(output: { data in
                buffer.append(data)
            }, exited: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.outputBuffer?.flush()
                        self?.ended = true
                    }
                }
            }, error: &error)
            if shell == nil {
                view.feed(text: "终端没能打开（错误 \(error)）\r\n")
            } else {
                shell?.resize(columns: Int32(terminal.cols), rows: Int32(terminal.rows))
            }
        }

        func shutdown() {
            outputBuffer?.close()
            outputBuffer = nil
            shell?.close()
            shell = nil
            far?.close()
            far = nil
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
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            UIApplication.shared.open(url)
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
                let connection = Connection(client)
                do {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
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
                    } onCancel: {
                        Task { await connection.close() }
                    }
                } catch {
                    await connection.close()
                    throw error
                }
                await connection.close()
                ended(nil)
            } catch is CancellationError {
                ended(nil)
            } catch let failed as SSHClient.CommandFailed {
                ended(Task.isCancelled || failed.exitCode == 0 ? nil : "退出码 \(failed.exitCode)")
            } catch {
                ended(Task.isCancelled ? nil : error.localizedDescription)
            }
        }
    }

    private actor Connection {
        private var client: SSHClient?
        init(_ client: SSHClient) { self.client = client }

        func close() async {
            guard let client else { return }
            self.client = nil
            try? await client.close()
        }
    }

    func send(_ data: Data) { feed.yield(.bytes(data)) }

    func resize(columns: Int, rows: Int) { feed.yield(.size(columns, rows)) }

    func close() {
        feed.finish()
        task?.cancel()
    }
}

/// Coalesces high-frequency PTY output chunks (~10ms window, 32KB cap) before feeding `TerminalView` on MainActor.
private final class OutputBuffer: @unchecked Sendable {
    private static let maxBufferedBytes = 32_768
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var timerScheduled = false
    private var immediateScheduled = false
    private var closed = false
    private let onFlush: @MainActor ([UInt8]) -> Void

    init(onFlush: @escaping @MainActor ([UInt8]) -> Void) {
        self.onFlush = onFlush
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var scheduleTimer = false
        var scheduleImmediate = false
        lock.lock()
        if !closed {
            bytes.append(contentsOf: data)
            if bytes.count >= Self.maxBufferedBytes {
                if !immediateScheduled {
                    immediateScheduled = true
                    scheduleImmediate = true
                }
            } else if !timerScheduled {
                timerScheduled = true
                scheduleTimer = true
            }
        }
        lock.unlock()

        if scheduleImmediate {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.flush()
                }
            }
        } else if scheduleTimer {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flush()
                }
            }
        }
    }

    @MainActor
    func flush() {
        let chunk: [UInt8] = lock.withLock {
            timerScheduled = false
            immediateScheduled = false
            guard !closed, !bytes.isEmpty else { return [] }
            let drained = bytes
            bytes.removeAll(keepingCapacity: true)
            return drained
        }
        guard !chunk.isEmpty else { return }
        onFlush(chunk)
    }

    func close() {
        lock.withLock {
            closed = true
            timerScheduled = false
            immediateScheduled = false
            bytes.removeAll()
        }
    }
}

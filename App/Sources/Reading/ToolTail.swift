import SwiftUI

/// What the command running right now is printing, a few lines at a time, for the status under the newest message.
@MainActor
final class ToolTail: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private nonisolated let buffer = Buffer()
    private var flushTask: Task<Void, Never>?

    /// The producer keeps only the newest lines, shows the first batch right away, and coalesces later bursts.
    nonisolated func add(_ text: String) {
        let parsed = Self.splitLines(text)
        guard let step = buffer.append(parsed) else { return }
        switch step.delivery {
        case .immediate(let firstBatch):
            let generation = step.generation
            Task { @MainActor [weak self] in
                guard let self, self.buffer.currentGeneration == generation else { return }
                self.lines = Array((self.lines + firstBatch.map { Line(text: $0) }).suffix(5))
            }
        case .throttled:
            let generation = step.generation
            Task { @MainActor [weak self] in
                self?.scheduleFlush(generation: generation)
            }
        }
    }

    func clear() {
        flushTask?.cancel()
        flushTask = nil
        buffer.clear()
        if !lines.isEmpty { lines = [] }
    }

    private func scheduleFlush(generation: UInt64) {
        guard buffer.currentGeneration == generation else { return }
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard let pending = self.buffer.drain(generation: generation), !pending.isEmpty else { return }
            self.lines = Array((self.lines + pending.map { Line(text: $0) }).suffix(5))
        }
    }

    nonisolated private static func splitLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { slice -> String? in
                let trimmed = slice.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return String(slice.prefix(240))
            }
            .suffix(5)
    }

    private enum Delivery: Sendable {
        case immediate([String])
        case throttled
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String] = []
        private var scheduled = false
        private var deliveredFirst = false
        private var generation: UInt64 = 0

        var currentGeneration: UInt64 {
            lock.withLock { generation }
        }

        func append(_ incoming: [String]) -> (delivery: Delivery, generation: UInt64)? {
            guard !incoming.isEmpty else { return nil }
            return lock.withLock {
                pending = Array((pending + incoming).suffix(5))
                if !deliveredFirst && !scheduled {
                    deliveredFirst = true
                    let batch = pending
                    pending.removeAll(keepingCapacity: true)
                    return (.immediate(batch), generation)
                }
                guard !scheduled else { return nil }
                scheduled = true
                return (.throttled, generation)
            }
        }

        func drain(generation expected: UInt64) -> [String]? {
            lock.withLock {
                guard generation == expected else { return nil }
                defer {
                    pending.removeAll(keepingCapacity: true)
                    scheduled = false
                }
                return pending
            }
        }

        func clear() {
            lock.withLock {
                generation &+= 1
                pending.removeAll(keepingCapacity: true)
                scheduled = false
                deliveredFirst = false
            }
        }
    }
}

/// The last few lines a running command printed.
struct ToolTailView: View {
    @ObservedObject var tail: ToolTail

    var body: some View {
        if !tail.lines.isEmpty {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                ForEach(tail.lines) { line in
                    Text(line.text)
                        .font(Ink.mono(Ink.Size.micro))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Ink.Code.output.opacity(0.65)).frame(width: 2.5)
            }
            .inkBlock()
            .accessibilityLabel("正在输出：" + (tail.lines.last?.text ?? ""))
        }
    }
}

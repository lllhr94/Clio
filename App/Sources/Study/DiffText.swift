import Craft
import SwiftUI

/// A hunk drawn the way people read changes: gone lines on a rose wash, new ones on a green wash.
struct DiffText: View {
    let hunk: String
    var limit = 40
    /// Long lines wrap instead of being cut (the full view).
    var wraps = false

    /// The first changed lines of a comparison, without the context around them.
    static func glance(_ full: String) -> String {
        full.components(separatedBy: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("+ ") }.prefix(5).joined(separator: "\n")
    }

    var body: some View {
        let lines = hunk.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: Ink.Size.micro, design: .monospaced))
                    .foregroundStyle(color(line))
                    .lineLimit(wraps ? nil : 1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(wash(line))
            }
            if lines.count > limit {
                Text("……还有 \(lines.count - limit) 行").font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(6)
            }
        }
        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.rule))
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix(Diff.marker) { return Ink.inkFaint }
        if line.hasPrefix("- ") { return Ink.stop }
        if line.hasPrefix("+ ") { return Ink.ok }
        return Ink.inkSoft
    }

    private func wash(_ line: String) -> Color {
        if line.hasPrefix("- ") { return Ink.stop.opacity(0.08) }
        if line.hasPrefix("+ ") { return Ink.ok.opacity(0.10) }
        if line.hasPrefix(Diff.marker) { return Ink.rule.opacity(0.4) }
        return .clear
    }
}

/// A changed file's whole comparison, every hunk.
struct DiffSheet: View {
    let title: String
    let place: String
    let diff: String
    let url: URL?
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    private var counts: (removed: Int, added: Int) {
        let lines = diff.components(separatedBy: "\n")
        return (lines.filter { $0.hasPrefix("- ") }.count, lines.filter { $0.hasPrefix("+ ") }.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    Text(place).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    HStack(spacing: Ink.Space.m) {
                        Label("删 \(counts.removed) 行", systemImage: "minus").foregroundStyle(Ink.stop)
                        Label("加 \(counts.added) 行", systemImage: "plus").foregroundStyle(Ink.ok)
                    }
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    DiffText(hunk: diff, limit: 4000, wraps: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("好了") { dismiss() } }
                if let url {
                    ToolbarItem(placement: .topBarTrailing) { Button("打开文件") { open(url) } }
                }
            }
        }
    }
}

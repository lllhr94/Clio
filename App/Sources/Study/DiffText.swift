import Craft
import SwiftUI

/// A hunk drawn the way people read changes: gone lines on a rose wash, new ones on a green wash.
struct DiffText: View {
    let hunk: String
    var limit = 40

    var body: some View {
        let lines = hunk.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(color(line))
                    .lineLimit(1)
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
        .clipShape(.rect(cornerRadius: Ink.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small).strokeBorder(Ink.rule))
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

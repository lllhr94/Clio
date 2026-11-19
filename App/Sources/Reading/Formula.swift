import SwiftMath
import SwiftUI
import UIKit

/// A display formula, typeset. While it is still arriving, or if it does not parse, the source shows instead.
/// It is typeset only once it comes near the screen: a long reply full of formulas would otherwise typeset them all at once and stutter.
struct FormulaBlock: View {
    let latex: String
    var streaming = false
    @State private var failed = false
    @State private var near = false
    @Environment(\.colorScheme) private var scheme

    /// Heights of formulas already typeset, so the stand-in before typesetting takes the same room and nothing shifts.
    @MainActor static var heights: [String: CGFloat] = [:]

    var body: some View {
        Group {
            if !near && !streaming {
                Text(latex)
                    .font(Ink.code)
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(1)
                    .padding(.horizontal, Ink.Space.m)
                    .frame(maxWidth: .infinity, minHeight: Self.heights[latex] ?? 58, maxHeight: Self.heights[latex] ?? 58)
            } else if streaming || failed {
                Text(latex)
                    .font(Ink.code)
                    .foregroundStyle(Ink.ink)
                    .padding(Ink.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    FormulaLabel(latex: latex, size: CGFloat(Pref.size) + 2, color: UIColor(Ink.ink), failed: $failed)
                        .padding(.vertical, Ink.Space.m)
                        .padding(.horizontal, Ink.Space.s)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, alignment: .center)
                .id(scheme)
            }
        }
        .background(Ink.accentWash.opacity(0.4), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .onGeometryChange(for: Bool.self) { proxy in
            // Within about a screen of the visible area.
            let frame = proxy.frame(in: .global)
            return frame.maxY > -900 && frame.minY < 1900
        } action: { close in
            if close, !near { near = true }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible, !near { near = true }
        }
        .contextMenu {
            Button("复制公式", systemImage: "doc.on.doc") { UIPasteboard.general.string = latex }
        }
    }
}

private struct FormulaLabel: UIViewRepresentable {
    let latex: String
    let size: CGFloat
    let color: UIColor
    @Binding var failed: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = .display
        label.textAlignment = .center
        configure(label)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.fontSize = size
        label.textColor = color
        if label.latex != latex { label.latex = latex }
        let bad = label.error != nil
        if bad != failed { DispatchQueue.main.async { failed = bad } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        if uiView.error == nil, size.height > 0 { FormulaBlock.heights[latex] = size.height + Ink.Space.m * 2 }
        return size
    }
}

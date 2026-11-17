import SwiftMath
import SwiftUI
import UIKit

/// A display formula, typeset. While it is still arriving, or if it does not parse, the source shows instead.
struct FormulaBlock: View {
    let latex: String
    var streaming = false
    @State private var failed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if streaming || failed {
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
        .background(Ink.accentWash.opacity(0.4), in: .rect(cornerRadius: Ink.Radius.small))
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
        uiView.intrinsicContentSize
    }
}

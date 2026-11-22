import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 选择文字: the reply as plain selectable text, to pick any words from it and copy them.
struct PickWords: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Selectable(text: text)
                .padding(.horizontal, Ink.Space.page)
                .background(Ink.paper.ignoresSafeArea())
                .navigationTitle("选择文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A read-only text view you can select in: drag the handles, then 拷贝.
struct Selectable: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 32, right: 0)
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: CGFloat(Pref.size)),
            .foregroundColor: UIColor(Ink.ink),
            .paragraphStyle: style,
        ])
    }
}

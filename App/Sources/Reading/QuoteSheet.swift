import SwiftUI
import UIKit

/// 引用追问: pick the words to ask about. Select part of the reply, or take all of it.
/// With `copying`, the same page picks words to copy: a long press on a reply opens its menu, so this is where part
/// of a reply can be selected.
struct QuoteSheet: View {
    let text: String
    var copying = false
    let done: (String?) -> Void
    @State private var selected = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Text(copying ? "拖选要复制的部分，不选就复制整段" : "拖选想追问的句子，不选就引整段")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.page)
                SelectableText(text: text, selected: $selected)
                    .padding(.horizontal, Ink.Space.m)
            }
            .padding(.top, Ink.Space.s)
            .background(Ink.paper)
            .navigationTitle(copying ? "选择文字" : L.t("chat.quoteFollowup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { done(nil) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copying ? (selected.isEmpty ? "复制整段" : "复制选中的") : (selected.isEmpty ? "引用整段" : "引用选中的")) {
                        Haptics.tick(0.6)
                        let picked = selected.isEmpty ? text : selected
                        if copying {
                            UIPasteboard.general.string = picked
                            done(nil)
                        } else {
                            done(String(picked.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)))
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// A read-only text view whose selection is reported back.
private struct SelectableText: UIViewRepresentable {
    let text: String
    @Binding var selected: String

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 24, right: 8)
        view.delegate = context.coordinator
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(Pref.leading)
        let font = Pref.face.postScript(bold: false).flatMap { UIFont(name: $0, size: CGFloat(Pref.size)) } ?? .systemFont(ofSize: CGFloat(Pref.size))
        view.attributedText = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: UIColor(Ink.ink)])
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var selected: String
        init(selected: Binding<String>) { _selected = selected }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            selected = range.length > 0 ? (textView.text as NSString).substring(with: range) : ""
        }
    }
}

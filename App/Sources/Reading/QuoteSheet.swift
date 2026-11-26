import SwiftUI
import UIKit

/// 引用追问: pick the words to ask about. Select part of the reply, or take all of it.
struct QuoteSheet: View {
    let text: String
    let done: (String?) -> Void
    @State private var selected = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Text("拖选想追问的句子，不选就引整段")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.page)
                SelectableText(text: text, selected: $selected)
                    .padding(.horizontal, Ink.Space.m)
            }
            .padding(.top, Ink.Space.s)
            .background(Ink.paper)
            .navigationTitle(L.t("chat.quoteFollowup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { done(nil) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selected.isEmpty ? "引用整段" : "引用选中的") {
                        Haptics.tick(0.6)
                        let picked = selected.isEmpty ? text : selected
                        done(String(picked.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)))
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
        let face = Pref.face
        let box = SafeLineBox.resolve(userSize: CGFloat(Pref.size), contentMultiplier: CGFloat(Pref.lineHeight), face: face)
        let font = Ink.uiFace(box.effectivePointSize, face: face)
        let style = box.makeParagraphStyle()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: UIColor(Ink.ink),
        ]
        if box.trackingPoints != 0 {
            attributes[.kern] = box.trackingPoints
        }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        ClioMixedScriptKerning.apply(to: attributed, fontSize: box.effectivePointSize, squeezePunctuation: Pref.clreqSqueeze)
        view.attributedText = attributed
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

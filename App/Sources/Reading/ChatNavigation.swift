import SwiftUI
import UIKit

final class ChatViewport {
    var ids: [String] = []
    var needsEndCorrection = false
}

struct ChatBrowserIndicator: View {
    @ObservedObject var browser: BrowserSession
    let open: () -> Void
    var body: some View {
        if browser.acting {
            Button(action: open) {
                Image(systemName: "globe")
                    .font(.system(size: Ink.Size.body, weight: .medium))
                    .symbolEffect(.pulse)
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassFace(in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(L.t("nav.browser"))
        }
    }
}

struct ChatShareSheet: UIViewControllerRepresentable {
    private let items: [Any]

    init(url: URL) { items = [url] }
    init(image: UIImage) { items = [image] }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

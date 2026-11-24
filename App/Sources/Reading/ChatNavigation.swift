import SwiftUI
import UIKit

final class ChatViewport {
    var ids: [String] = []
    var needsEndCorrection = false
    private var jump: (source: String, at: TimeInterval)?

    func recordJump(_ source: String) {
        jump = (source, ProcessInfo.processInfo.systemUptime)
    }

    var recentJump: String? {
        guard let jump, ProcessInfo.processInfo.systemUptime - jump.at < 1 else { return nil }
        return jump.source
    }
}

struct ChatScrollSample: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
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

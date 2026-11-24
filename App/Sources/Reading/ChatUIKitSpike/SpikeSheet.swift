import SwiftUI
import UIKit

struct SpikeChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.shared
        let styleSignal = "\(theme.key)|\(theme.face.rawValue)|\(theme.code.rawValue)|\(theme.size)|\(theme.lineHeight)|\(theme.white)|\(theme.oled)|\(theme.bubble)|\(UIScale.shared.value)|\(colorScheme == .dark)"
        SpikeChatRepresentable(styleSignal: styleSignal) {
            dismiss()
        }
        .background(Ink.paper.ignoresSafeArea())
        .ignoresSafeArea()
        .hitchPage("UIKit原型")
    }
}

private struct SpikeChatRepresentable: UIViewControllerRepresentable {
    let styleSignal: String
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(lastSignal: styleSignal)
    }

    func makeUIViewController(context: Context) -> SpikeChatViewController {
        let controller = SpikeChatViewController()
        controller.onDismiss = onDismiss
        return controller
    }

    func updateUIViewController(_ uiViewController: SpikeChatViewController, context: Context) {
        uiViewController.onDismiss = onDismiss
        if context.coordinator.lastSignal != styleSignal {
            context.coordinator.lastSignal = styleSignal
            uiViewController.refreshTypographyAndTheme()
        }
    }

    final class Coordinator {
        var lastSignal: String
        init(lastSignal: String) {
            self.lastSignal = lastSignal
        }
    }
}

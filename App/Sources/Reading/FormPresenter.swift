import SwiftUI

/// A visible browser sheet owns the form it can present above itself; otherwise the root owns it.
@MainActor
private final class FormPlacement: ObservableObject {
    static let shared = FormPlacement()
    @Published var browser: UUID?
}

struct FormPresenter: ViewModifier {
    let inBrowser: Bool
    @ObservedObject private var asker = Asker.shared
    @ObservedObject private var placement = FormPlacement.shared
    @State private var token = UUID()
    @State private var sheet: Asker.Form?
    @State private var displayed: UUID?

    private var ownsPresentation: Bool {
        inBrowser ? placement.browser == token : placement.browser == nil
    }

    private var eligible: Asker.Form? { ownsPresentation ? asker.current : nil }

    func body(content: Content) -> some View {
        content
            .onAppear { if inBrowser { placement.browser = token } }
            .onDisappear { if inBrowser, placement.browser == token { placement.browser = nil } }
            .task(id: eligible?.id) {
                guard let form = eligible else { sheet = nil; return }
                if !inBrowser, form.inline {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, eligible?.id == form.id, !asker.inlineSeen else { return }
                }
                sheet = form
            }
            .sheet(item: $sheet, onDismiss: {
                if ownsPresentation, let displayed, asker.current?.id == displayed { asker.cancel(displayed) }
                displayed = nil
            }) { form in
                FormSheet(form: form).onAppear { displayed = form.id }
            }
    }
}

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
    @State private var presented: UUID?

    private var ownsPresentation: Bool {
        inBrowser ? placement.browser == token : placement.browser == nil
    }

    private func matchesBrowser(_ form: Asker.Form) -> Bool {
        guard let chat = form.chat else { return true }
        guard let browser = RoamTools.browser else { return false }
        return chat == browser.handoffChat || chat == browser.owner(of: browser.view)
    }

    private var eligible: Asker.Form? {
        guard ownsPresentation, let form = asker.current else { return nil }
        if inBrowser, !matchesBrowser(form) { return nil }
        return form
    }

    private struct Update: Equatable {
        let eligible: UUID?
        let presented: UUID?
    }

    func body(content: Content) -> some View {
        content
            .onAppear { if inBrowser { placement.browser = token } }
            .onDisappear { if inBrowser, placement.browser == token { placement.browser = nil } }
            .task(id: Update(eligible: eligible?.id, presented: presented)) {
                if let presented {
                    // Wait for this sheet's onDismiss before showing the next one.
                    if presented != eligible?.id { sheet = nil }
                    return
                }
                guard let form = eligible else { return }
                if !inBrowser, form.inline {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, eligible?.id == form.id, !asker.inlineSeen.contains(form.id) else { return }
                }
                presented = form.id
                sheet = form
            }
            .sheet(item: $sheet, onDismiss: {
                let id = presented
                if ownsPresentation, let id, asker.current?.id == id { asker.cancel(id) }
                presented = nil
            }) { form in
                FormSheet(form: form)
            }
    }
}

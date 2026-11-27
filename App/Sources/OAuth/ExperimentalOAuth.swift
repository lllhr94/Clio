import Foundation
import SwiftUI

enum ExperimentalOAuth {
    static let initiallyExpanded = false
    static let providers = ["OpenAI Codex", "Anthropic Claude", "xAI Grok", "GitHub Copilot"]

    struct Registration {
        let clientID: String
        let callback: URL

        init?(clientID: String, callback: URL) {
            guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let port = callback.port, callback == OAuthLoopbackAddress.callback(port: port) else { return nil }
            self.clientID = clientID
            self.callback = callback
        }
    }
}

struct ExperimentalOAuthSection: View {
    @State private var expanded = ExperimentalOAuth.initiallyExpanded

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Text(L.t("services.oauthExperimentalNote"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                ForEach(ExperimentalOAuth.providers, id: \.self) { name in
                    HStack {
                        Text(name).font(Ink.label).foregroundStyle(Ink.ink)
                        Spacer(minLength: Ink.Space.s)
                        ServiceStamp(title: L.t("services.oauthUnverified"))
                    }
                }
            }
            .padding(.top, Ink.Space.m)
        } label: {
            Text(L.t("services.oauthExperimental")).font(Ink.label).foregroundStyle(Ink.ink)
        }
        .tint(Ink.accent)
        .padding(Ink.Space.l)
        .paperCard()
    }
}

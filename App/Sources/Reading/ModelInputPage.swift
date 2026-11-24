import SwiftUI
import UIKit

struct ModelInputPage: View {
    let team: TeamModel
    let chat: String
    @ObservedObject private var log: ModelInputLog

    init(team: TeamModel, chat: String) {
        self.team = team
        self.chat = chat
        self.log = team.modelInputLog
    }

    var body: some View {
        let requests = team.modelInputs(chat)
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                Text(L.t("modelInput.retention"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                if requests.isEmpty {
                    Text(L.t("modelInput.noRequests"))
                        .font(Ink.body(Double(Ink.Size.body), bold: false))
                        .foregroundStyle(Ink.ink)
                        .padding(Ink.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(requests) { request in
                            NavigationLink {
                                ModelInputDetail(input: request)
                            } label: {
                                requestRow(request)
                            }
                            .buttonStyle(TapStyle())
                            if request.id != requests.last?.id { Kit.rule() }
                        }
                    }
                    .paperCard()
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(L.t("modelInput.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestRow(_ input: ModelInput) -> some View {
        HStack(spacing: Ink.Space.m) {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(verbatim: input.model)
                    .font(Ink.mono(Ink.Size.sub))
                    .foregroundStyle(Ink.ink)
                Text(input.at, format: .dateTime.month().day().hour().minute().second())
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
            }
            Spacer(minLength: Ink.Space.s)
            Kit.chevron
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.s)
        .frame(minHeight: Kit.rowHeight)
        .contentShape(Rectangle())
    }
}

private struct ModelInputDetail: View {
    let input: ModelInput

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.l) {
                ModelInputBlock(
                    title: L.t("modelInput.conversation"),
                    text: L.format("modelInput.messageCount", input.messages, input.characters)
                )
                ModelInputBlock(title: L.t("modelInput.system"), text: input.system)
                ModelInputBlock(title: L.t("modelInput.memory"), text: input.memory)
                ModelInputBlock(title: L.t("modelInput.skills"), text: input.skills)
                ModelInputBlock(title: L.t("modelInput.tools"), text: input.tools, monospaced: true)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.vertical, Ink.Space.l)
        }
        .background(Ink.paper.ignoresSafeArea())
        .navigationTitle(Text(verbatim: input.model))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelInputBlock: View {
    let title: String
    let text: String
    var monospaced = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                SectionTitle(title)
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Button(copied ? L.t("actions.copied") : L.t("actions.copy")) {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
                        copied = true
                    }
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.accent)
                    .padding(.trailing, Ink.Space.l)
                    .buttonStyle(TapStyle())
                }
            }
            Text(verbatim: text.isEmpty ? L.t("modelInput.none") : text)
                .font(monospaced ? Ink.mono(Ink.Size.small) : Ink.body(Double(Ink.Size.sub), bold: false))
                .foregroundStyle(text.isEmpty ? Ink.inkSoft : Ink.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Ink.Space.l)
                .paperCard()
        }
    }
}

import SwiftUI

struct MemoryReviewHistory: View {
    let records: [MemoryReviewLog]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryReview.title"))
            if records.isEmpty {
                Text(L.t("memoryReview.empty"))
                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)
            } else {
                RowCard {
                    ForEach(records) { record in
                        DisclosureGroup {
                            details(record)
                        } label: {
                            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                                Text(record.conversation).font(Ink.label).foregroundStyle(Ink.ink)
                                Text(L.format("memoryReview.record", record.day,
                                              record.at.formatted(date: .abbreviated, time: .shortened)))
                                    .font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                            }
                        }
                        .padding(Ink.Space.l)
                    }
                }
            }
        }
    }

    private func details(_ record: MemoryReviewLog) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if record.added.isEmpty, record.merged.isEmpty {
                Text(L.t("memoryReview.noChanges")).foregroundStyle(Ink.inkSoft)
            }
            ForEach(Array(record.added.enumerated()), id: \.offset) { _, item in
                Text(L.format("memoryReview.added", item.text))
            }
            ForEach(Array(record.merged.enumerated()), id: \.offset) { _, change in
                Text(L.format("memoryReview.merged", change.before, change.after))
            }
        }
        .font(Ink.secondary)
        .foregroundStyle(Ink.ink)
        .padding(.top, Ink.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

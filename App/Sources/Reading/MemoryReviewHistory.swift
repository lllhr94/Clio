import SwiftUI

struct MemoryReviewHistory: View {
    let records: [MemoryReviewLog]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryReview.title"))
            if records.isEmpty {
                Text(L.t("memoryReview.empty"))
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.l)
                    .paperCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            Kit.rule(inset: Ink.Space.l)
                        }
                        DisclosureGroup {
                            details(record)
                        } label: {
                            recordHeader(record)
                        }
                        .tint(Ink.accent)
                        .padding(Ink.Space.l)
                    }
                }
                .paperCard()
            }
        }
    }

    private func recordHeader(_ record: MemoryReviewLog) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack(spacing: Ink.Space.xs) {
                Text(record.conversation)
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !record.added.isEmpty {
                    countPill("+\(record.added.count)", tint: Ink.ok)
                }
                if !record.merged.isEmpty {
                    countPill("~\(record.merged.count)", tint: Ink.accent)
                }
            }

            Text(
                L.format(
                    "memoryReview.record",
                    record.day,
                    record.at.formatted(date: .abbreviated, time: .shortened)
                )
            )
            .font(Ink.footnote)
            .foregroundStyle(Ink.inkSoft)
        }
    }

    private func countPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: Ink.Size.micro, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, Ink.Space.xs / 2)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func details(_ record: MemoryReviewLog) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if record.added.isEmpty, record.merged.isEmpty {
                Text(L.t("memoryReview.noChanges"))
                    .foregroundStyle(Ink.inkSoft)
            }
            ForEach(Array(record.added.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.ok)
                    Text(L.format("memoryReview.added", item.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(record.merged.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.accent)
                    Text(L.format("memoryReview.merged", change.before, change.after))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(Ink.secondary)
        .foregroundStyle(Ink.ink)
        .padding(.top, Ink.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

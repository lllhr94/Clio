import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: Finding

    var currentHit: String? {
        let found = hits
        guard !found.isEmpty else { return nil }
        return found[min(max(findAt, 0), found.count - 1)]
    }

    /// Everything said is looked through, not only what is on screen.
    func startFinding() {
        Haptics.light()
        settleJump?.cancel()
        viewport.advanceNavigation()
        withAnimation(Ink.Motion.settle) { finding = true }
        findFocus = true
        findLoadTask?.cancel()
        findLoadTask = Task {
            let rows = await chat.lookupRows()
            guard !Task.isCancelled, finding else { return }
            lookupRows = rows
            updateFindHits()
        }
    }

    /// The whole conversation, built once, for finding and the outline. Rows are only put on the page when going there.
    func loadEverything() async {
        lookupRows = await chat.lookupRows()
    }

    func cancelFindTasks() {
        findLoadTask?.cancel()
        findQueryTask?.cancel()
        findScrollTask?.cancel()
    }

    func stopFinding() {
        cancelFindTasks()
        withAnimation(Ink.Motion.settle) { finding = false }
        findText = ""
        findAt = 0
        hits = []
        lookupRows = []
    }

    /// Keep a bounded window around the result, without altering the live conversation's paging.
    func reveal(_ id: String) {
        if chat.lines.suffix(shownCount).contains(where: { $0.id == id }) {
            historyPage = nil
            return
        }
        guard let index = lookupRows.firstIndex(where: { $0.id == id }) else { return }
        let bounds = max(0, index - 30)..<min(lookupRows.count, index + 31)
        historyPage = Array(lookupRows[bounds])
    }

    func updateFindHits() {
        findQueryTask?.cancel()
        findScrollTask?.cancel()
        hits = []
        findAt = 0
        let wanted = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !lookupRows.isEmpty else { return }
        let rows = lookupRows
        findQueryTask = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let search = Task.detached(priority: .userInitiated) {
                var result: [String] = []
                for row in rows {
                    if Task.isCancelled { return [] as [String] }
                    if (row.kind == .user || row.kind == .bot), row.text.localizedCaseInsensitiveContains(wanted) {
                        result.append(row.id)
                    }
                }
                return result
            }
            let found = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
            guard !Task.isCancelled, finding else { return }
            hits = found
            findAt = max(found.count - 1, 0)
            if !found.isEmpty { showHit(0) }
        }
    }

    /// Goes to the place found, newest first; the arrows step older or newer.
    func showHit(_ step: Int) {
        let found = hits
        guard !found.isEmpty else { return }
        findAt = (findAt + step + found.count) % found.count
        let target = found[findAt]
        settleJump?.cancel()
        viewport.advanceNavigation()
        let generation = viewport.navigationGeneration
        reveal(target)
        following = false
        Haptics.tick(0.4)
        findScrollTask?.cancel()
        findScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, finding,
                  generation == viewport.navigationGeneration else { return }
            viewport.recordJump("点了搜索结果")
            withAnimation(Ink.Motion.settle) { scroller?.scrollTo(target, anchor: .center) }
        }
    }

    /// Where the composer was, while looking: the words, how many places, older / newer, and 完成.
    var findBar: some View {
        let found = hits.count
        return HStack(spacing: Ink.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.inkFaint)
            TextField("在这段对话里找", text: $findText)
                .font(.system(size: Ink.Size.body))
                .focused($findFocus)
                .submitLabel(.search)
                .onSubmit { showHit(-1) }
                .onChange(of: findText) { updateFindHits() }
            if !findText.isEmpty {
                Text(found == 0 ? "没找到" : "\(min(findAt + 1, found))/\(found)")
                    .font(Ink.footnote.monospacedDigit())
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize()
            }
            Button { showHit(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(found == 0)
                .accessibilityLabel("更早的一处")
            Button { showHit(1) } label: { Image(systemName: "chevron.down") }
                .disabled(found == 0)
                .accessibilityLabel("更新的一处")
            Button(L.t("actions.done")) { stopFinding() }
                .font(.system(size: Ink.Size.sub, weight: .semibold))
        }
        .font(.system(size: Ink.Size.sub, weight: .semibold))
        .foregroundStyle(Ink.accent)
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: 48)
        .glassFace(in: Capsule())
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.bottom, Ink.Space.s)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

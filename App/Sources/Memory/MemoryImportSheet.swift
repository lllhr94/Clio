import Craft
import SwiftUI
import UniformTypeIdentifiers

struct MemoryImportSheet: View {
    @ObservedObject var team: TeamModel
    var onImported: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var rawText = ""
    @State private var defaultLayer: MemoryLayer = .surface
    @State private var pickingFile = false
    @State private var loadingFile = false
    @State private var loadedFileName: String?
    @State private var fileError: String?
    @State private var candidates: [MemoryImportCandidate] = []
    @State private var skipped: [MemoryImportSkippedItem] = []
    @State private var commitNotice: String?

    @State private var layerOverrides: [String: MemoryLayer] = [:]
    @State private var cachedSecrets: [String] = []
    @State private var cachedExistingTexts: [String] = []
    @State private var cachedSuppressedHashes: Set<String> = []
    @State private var parseTask: Task<Void, Never>?
    @State private var parseGeneration = 0
    @State private var skipNextParseDebounce = false
    @State private var committing = false

    private static let maxImportBytes = 1_048_576

    private static var importableContentTypes: [UTType] {
        [
            .plainText,
            .text,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
    }

    private var availableLayers: [MemoryLayer] {
        team.keeping ? MemoryLayer.allCases : [.surface, .deep]
    }

    private var selectedCount: Int {
        candidates.reduce(0) { $0 + ($1.selected ? 1 : 0) }
    }

    private var allSelected: Bool {
        !candidates.isEmpty && selectedCount == candidates.count
    }

    private var confirmButtonTitle: String {
        if selectedCount > 0 {
            return L.format("memoryImport.confirmCount", selectedCount)
        }
        return L.t("memoryImport.confirmButton")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    inputSection
                    layerSection
                    previewSection
                    if !skipped.isEmpty {
                        skippedSection
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("memoryImport.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmButtonTitle) {
                        commitImport()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCount == 0 || loadingFile || committing || !team.canMutateMemoryState)
                }
            }
            .fileImporter(
                isPresented: $pickingFile,
                allowedContentTypes: Self.importableContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePickedFile(result)
            }
            .alert(
                commitNotice ?? "",
                isPresented: Binding(
                    get: { commitNotice != nil },
                    set: { if !$0 { commitNotice = nil } }
                )
            ) {
                Button(L.t("actions.done"), role: .cancel) {
                    commitNotice = nil
                }
            }
            .onChange(of: rawText) { _, _ in
                let delayMs = skipNextParseDebounce ? 0 : 250
                skipNextParseDebounce = false
                scheduleReparse(preservingSelectionsAndLayers: true, debounceMs: delayMs)
            }
            .onChange(of: defaultLayer) { _, _ in
                scheduleReparse(preservingSelectionsAndLayers: true, debounceMs: 0)
            }
            .task {
                await loadImportContext()
            }
            .onDisappear {
                parseTask?.cancel()
            }
        }
    }

    // MARK: - Sections

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryImport.pasteSection"))
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if rawText.isEmpty {
                        Text(L.t("memoryImport.pastePlaceholder"))
                            .font(.system(size: Ink.Size.sub))
                            .foregroundStyle(Ink.inkFaint)
                            .padding(.horizontal, Ink.Space.l)
                            .padding(.vertical, Ink.Space.m + Ink.Space.xs)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $rawText)
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 220)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                }

                Kit.rule(inset: Ink.Space.l)

                HStack(spacing: Ink.Space.m) {
                    Button {
                        Haptics.light()
                        pickingFile = true
                    } label: {
                        Label(L.t("memoryImport.pickFile"), systemImage: "doc.badge.plus")
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(Ink.accent)
                    }
                    .buttonStyle(TapStyle())
                    .disabled(loadingFile)

                    if loadingFile {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer(minLength: Ink.Space.s)

                    if !rawText.isEmpty {
                        Button {
                            Haptics.light()
                            rawText = ""
                            loadedFileName = nil
                            fileError = nil
                            layerOverrides = [:]
                        } label: {
                            Text(L.t("memoryImport.clearInput"))
                                .font(.system(size: Ink.Size.sub))
                                .foregroundStyle(Ink.inkSoft)
                        }
                        .buttonStyle(TapStyle())
                    }
                }
                .padding(.horizontal, Ink.Space.l)
                .padding(.vertical, Ink.Space.m)
            }
            .paperCard()

            if let loadedFileName {
                Text(L.format("memoryImport.loadedFile", loadedFileName))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.ok)
                    .padding(.horizontal, Ink.Space.l)
            }
            if let fileError {
                Text(fileError)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.stop)
                    .padding(.horizontal, Ink.Space.l)
            }
        }
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.t("memoryImport.defaultLayerLabel"))
            if typeSize.isAccessibilitySize {
                WrapLayout(spacing: Ink.Space.s) {
                    ForEach([MemoryLayer.surface, MemoryLayer.deep], id: \.self) { option in
                        let selected = defaultLayer == option
                        Button {
                            Haptics.tick(0.45)
                            defaultLayer = option
                        } label: {
                            Text(MemoryV2Copy.layerTitle(option))
                                .font(.system(size: Ink.Size.sub, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Ink.paper : Ink.ink)
                                .padding(.horizontal, Ink.Space.m)
                                .padding(.vertical, Ink.Space.xs)
                                .background(selected ? Ink.accent : Ink.rule.opacity(0.45), in: Capsule())
                        }
                        .buttonStyle(TapStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            } else {
                SlidingCapsuleControl(
                    selection: $defaultLayer,
                    options: [MemoryLayer.surface, MemoryLayer.deep]
                ) { MemoryV2Copy.layerTitle($0) }
                .accessibilityLabel(L.t("memoryImport.defaultLayerLabel"))
            }

            if team.keeping {
                Text(L.t("memoryImport.defaultLayerNote"))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(L.t("memoryImport.previewSection"))
                Spacer(minLength: Ink.Space.s)
                if !candidates.isEmpty {
                    Button {
                        Haptics.tick(0.4)
                        let next = !allSelected
                        for index in candidates.indices {
                            candidates[index].selected = next
                        }
                    } label: {
                        Text(allSelected ? L.t("memoryImport.deselectAll") : L.t("memoryImport.selectAll"))
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.accent)
                    }
                    .buttonStyle(TapStyle())
                    .padding(.trailing, Ink.Space.l)
                }
            }

            if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L.t("memoryImport.previewEmpty"))
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(Ink.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()
            } else {
                Text(L.format("memoryImport.previewSummary", selectedCount, candidates.count, skipped.count))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)

                if !candidates.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Kit.rule(inset: Ink.Space.l)
                            }
                            candidateRow(item)
                        }
                    }
                    .paperCard()
                }
            }
        }
    }

    private func candidateRow(_ item: MemoryImportCandidate) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.m) {
            Button {
                Haptics.tick(0.45)
                toggleSelection(id: item.id)
            } label: {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Ink.Size.title))
                    .foregroundStyle(item.selected ? Ink.accent : Ink.inkFaint)
                    .padding(.top, Ink.Space.xs / 2)
            }
            .buttonStyle(TapStyle(grow: Ink.Space.xs))
            .accessibilityLabel(item.text)
            .accessibilityValue(item.selected ? L.t("memoryImport.selectedState") : L.t("memoryImport.unselectedState"))

            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                Text(item.text)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(item.selected ? Ink.ink : Ink.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tick(0.45)
                        toggleSelection(id: item.id)
                    }

                WrapLayout(spacing: Ink.Space.xs) {
                    Menu {
                        ForEach(availableLayers, id: \.self) { layer in
                            Button {
                                setTargetLayer(id: item.id, layer: layer)
                            } label: {
                                if layer == item.targetLayer {
                                    Label(MemoryV2Copy.layerTitle(layer), systemImage: "checkmark")
                                } else {
                                    Text(MemoryV2Copy.layerTitle(layer))
                                }
                            }
                        }
                    } label: {
                        MemoryBadgePill(
                            text: MemoryV2Copy.layerTitle(item.targetLayer),
                            foreground: MemoryV2Copy.layerTint(item.targetLayer),
                            background: MemoryV2Copy.layerWash(item.targetLayer)
                        )
                    }

                    if !item.kind.isEmpty && item.kind != "fact" {
                        MemoryBadgePill(
                            text: MemoryV2Copy.kindTitle(item.kind),
                            foreground: Ink.inkSoft,
                            background: Ink.rule.opacity(0.55)
                        )
                    }

                    if !item.topic.isEmpty {
                        MemoryBadgePill(
                            text: item.topic,
                            foreground: Ink.inkSoft,
                            background: Ink.rule.opacity(0.45)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.m)
    }

    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle(L.format("memoryImport.skippedSection", skipped.count))
            LazyVStack(spacing: 0) {
                ForEach(Array(skipped.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Kit.rule(inset: Ink.Space.l)
                    }
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        Text(item.reason == .secretDetected ? L.t("memoryImport.secretBlockedPreview") : item.text)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MemoryBadgePill(
                            text: item.reasonText,
                            foreground: item.reason == .secretDetected ? Ink.stop : Ink.warn,
                            background: (item.reason == .secretDetected ? Ink.stop : Ink.warn).opacity(0.14)
                        )
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                }
            }
            .paperCard()
        }
    }

    // MARK: - Actions

    private func toggleSelection(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].selected.toggle()
    }

    private func setTargetLayer(id: String, layer: MemoryLayer) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let resolved: MemoryLayer
        if team.keeping {
            resolved = layer
        } else {
            resolved = (layer == .deep) ? .deep : .surface
        }
        candidates[index].targetLayer = resolved
        let key = MemorySafety.normalizedFactKey(candidates[index].text)
        if !key.isEmpty {
            layerOverrides[key] = resolved
        }
    }

    private func loadImportContext() async {
        let liveTexts = team.memories.map(\.text)
        let promptSuppressed = team.memoryPromptState.suppressedFlushHashesSnapshot()
        let keeping = team.keeping

        let snapshot = await Task.detached(priority: .userInitiated) {
            let secrets = Vault.allStrings()
            let archivedTexts = keeping
                ? MemoryStoreBridge.shared.recordsSnapshot(layer: .archived).map(\.text)
                : []
            return (secrets: secrets, archivedTexts: archivedTexts)
        }.value

        cachedSecrets = snapshot.secrets
        cachedExistingTexts = liveTexts + snapshot.archivedTexts
        cachedSuppressedHashes = promptSuppressed
        scheduleReparse(preservingSelectionsAndLayers: true, debounceMs: 0)
    }

    private func scheduleReparse(preservingSelectionsAndLayers: Bool, debounceMs: Int) {
        parseTask?.cancel()
        parseGeneration &+= 1
        let generation = parseGeneration
        let text = rawText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates = []
            skipped = []
            return
        }
        let layer = defaultLayer
        let existingTexts = cachedExistingTexts
        let suppressedHashes = cachedSuppressedHashes
        let secrets = cachedSecrets
        let keeping = team.keeping
        let overrides = layerOverrides
        let deselectedKeys: Set<String> = preservingSelectionsAndLayers
            ? Set(candidates.filter { !$0.selected }.map { MemorySafety.normalizedFactKey($0.text) })
            : []

        parseTask = Task {
            if debounceMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounceMs))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (candidates: [MemoryImportCandidate], skipped: [MemoryImportSkippedItem]) in
                let retractedCheck: ((String) -> Bool)? = keeping
                    ? { MemoryStoreBridge.shared.isSuppressedInShadow(text: $0) }
                    : nil
                let preview = MemoryImporter.parse(
                    text,
                    defaultLayer: layer,
                    existingTexts: existingTexts,
                    suppressedHashes: suppressedHashes,
                    secrets: secrets,
                    isRetracted: retractedCheck
                )
                var nextCandidates = preview.candidates
                for index in nextCandidates.indices {
                    let key = MemorySafety.normalizedFactKey(nextCandidates[index].text)
                    if preservingSelectionsAndLayers && deselectedKeys.contains(key) {
                        nextCandidates[index].selected = false
                    }
                    if preservingSelectionsAndLayers, let override = overrides[key] {
                        nextCandidates[index].targetLayer = override
                    }
                    if !keeping && (nextCandidates[index].targetLayer == .pinned || nextCandidates[index].targetLayer == .archived) {
                        nextCandidates[index].targetLayer = layer
                    }
                }
                return (nextCandidates, preview.skipped)
            }.value
            guard !Task.isCancelled, generation == parseGeneration else { return }
            candidates = result.candidates
            skipped = result.skipped
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if error is CancellationError {
                return
            }
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                return
            }
            fileError = L.format("memoryImport.filePickFailed", error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            loadingFile = true
            fileError = nil

            Task {
                defer { loadingFile = false }
                let loadResult = await Self.readTextFile(
                    at: url,
                    hasSecurityScope: hasSecurityScope,
                    maxBytes: Self.maxImportBytes
                )
                switch loadResult {
                case .success(let decoded):
                    fileError = nil
                    layerOverrides = [:]
                    loadedFileName = url.lastPathComponent
                    skipNextParseDebounce = true
                    rawText = decoded
                case .failure(let errorKey):
                    fileError = L.t(errorKey)
                }
            }
        }
    }

    private enum FileReadResult: Sendable {
        case success(String)
        case failure(String)
    }

    private nonisolated static func readTextFile(
        at url: URL,
        hasSecurityScope: Bool,
        maxBytes: Int
    ) async -> FileReadResult {
        await Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == false {
                    return .failure("memoryImport.fileNotRegularError")
                }
                if let fileSize = values.fileSize, fileSize > maxBytes {
                    return .failure("memoryImport.fileReadError")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= maxBytes else {
                    return .failure("memoryImport.fileReadError")
                }
                if let utf8 = String(data: data, encoding: .utf8) {
                    return .success(utf8)
                }
                if let utf16 = String(data: data, encoding: .utf16) {
                    return .success(utf16)
                }
                return .failure("memoryImport.fileEncodingError")
            } catch {
                return .failure("memoryImport.fileReadError")
            }
        }.value
    }

    private func commitImport() {
        guard !committing else { return }
        let payload = candidates
            .filter(\.selected)
            .map { (text: $0.text, layer: $0.targetLayer, kind: $0.kind, topic: $0.topic) }
        guard !payload.isEmpty else { return }

        committing = true
        commitNotice = nil
        Task {
            do {
                let count = try await team.importMemoryCandidatesOffMain(payload)
                committing = false
                if count > 0 {
                    Haptics.tick(0.8)
                    onImported?(count)
                    dismiss()
                } else {
                    Haptics.thud()
                    commitNotice = L.t("memoryImport.noneCommitted")
                    await loadImportContext()
                }
            } catch {
                committing = false
                Haptics.lock()
                commitNotice = error.localizedDescription
            }
        }
    }
}

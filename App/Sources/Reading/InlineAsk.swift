import Craft
import SwiftUI

/// A companion's short question (ask_user with nothing secret), answered in the conversation itself:
/// single-select, multi-select, optional inline custom input, or short text fields.
/// Anything secret NEVER uses this view and routes strictly to `FormSheet`.
struct InlineAsk: View {
    let form: Asker.Form

    @State private var selectedByKey: [String: [String]] = [:]
    @State private var customByKey: [String: String] = [:]
    @State private var customOpenKeys: Set<String> = []
    @State private var limitWarningKey: String?

    init(form: Asker.Form) {
        self.form = form
        var initialSelected: [String: [String]] = [:]
        var initialCustom: [String: String] = [:]
        var initialOpen: Set<String> = []
        var unusedValues: [String: String] = [:]
        AskSheetLogic.seedNonSecretState(
            fields: form.fields,
            selectedByKey: &initialSelected,
            customByKey: &initialCustom,
            customOpenKeys: &initialOpen,
            values: &unusedValues,
            usesSegmentedPicker: { _ in false }
        )
        _selectedByKey = State(initialValue: initialSelected)
        _customByKey = State(initialValue: initialCustom)
        _customOpenKeys = State(initialValue: initialOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            header
            if !form.reason.isEmpty {
                Text(form.reason)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(form.fields) { field in
                fieldSection(for: field)
            }
            if let error = activeValidationError {
                Text(error)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.stop)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerButtons
        }
        .padding(Ink.Space.l)
        .paperCard()
        .onAppear { Asker.shared.inlineSeen.insert(form.id) }
        .onDisappear { Asker.shared.inlineSeen.remove(form.id) }
    }

    private var header: some View {
        HStack(spacing: Ink.Space.s) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(Ink.accent)
            Text(L.format("ask.questionHeader", form.from, form.title))
                .font(.system(size: Ink.Size.sub, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldSection(for field: Asker.Field) -> some View {
        if field.secret || form.requiresVault {
            Label(L.t("forms.secretNote"), systemImage: "lock.shield")
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkFaint)
        } else {
            AskFieldControl(
                field: field,
                showLabel: form.fields.count > 1 || (!field.label.isEmpty && field.label != form.title),
                selected: selectedBinding(for: field.key),
                customText: customBinding(for: field.key),
                isCustomOpen: customOpenBinding(for: field.key),
                limitWarning: limitWarningKey == field.key,
                onLimitHit: { triggerLimitWarning(for: field.key) }
            )
        }
    }

    private var footerButtons: some View {
        HStack {
            Button(L.t("actions.cancel")) {
                Haptics.light()
                Asker.shared.cancel(form.id)
            }
            .foregroundStyle(Ink.inkSoft)
            .buttonStyle(.plain)
            Spacer()
            Button(L.t("actions.submitForm")) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Ink.accent)
            .disabled(!canSubmit)
        }
        .font(.system(size: Ink.Size.sub, weight: .semibold))
    }

    private var activeValidationError: String? {
        AskSheetLogic.activeInputError(for: form.fields, responseProvider: currentResponse(for:))
    }

    private var canSubmit: Bool {
        guard !form.requiresVault, !form.fields.contains(where: \.secret) else { return false }
        var hasAnyNonEmpty = false
        for field in form.fields {
            let response = currentResponse(for: field)
            guard let validated = AskSheetLogic.validatedNonSecretField(field, response: response) else {
                return false
            }
            if !validated.selected.isEmpty || (validated.customText?.isEmpty == false) {
                hasAnyNonEmpty = true
            }
        }
        let allLegacyDefaultText = form.fields.allSatisfy { !$0.required && !$0.optionalBadge && $0.effectiveKind == .text }
        if allLegacyDefaultText && !hasAnyNonEmpty { return false }
        return true
    }

    private func currentResponse(for field: Asker.Field) -> AskResponse {
        AskSheetLogic.response(
            for: field,
            selectedByKey: selectedByKey,
            customByKey: customByKey,
            customOpenKeys: customOpenKeys
        )
    }

    private func submit() {
        var encoded: [String: String] = [:]
        for field in form.fields where !field.secret {
            let response = currentResponse(for: field)
            encoded[field.key] = AskSheetLogic.encodedNonSecretField(field, response: response)
        }
        Haptics.grab()
        Asker.shared.answer(encoded, to: form.id)
    }

    private func triggerLimitWarning(for key: String) {
        Haptics.light()
        withAnimation(Ink.Motion.press) { limitWarningKey = key }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if limitWarningKey == key {
                withAnimation(Ink.Motion.settle) { limitWarningKey = nil }
            }
        }
    }

    private func selectedBinding(for key: String) -> Binding<[String]> {
        Binding(
            get: { selectedByKey[key] ?? [] },
            set: { selectedByKey[key] = $0 }
        )
    }

    private func customBinding(for key: String) -> Binding<String> {
        Binding(
            get: { customByKey[key] ?? "" },
            set: { customByKey[key] = $0 }
        )
    }

    private func customOpenBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { customOpenKeys.contains(key) },
            set: { open in
                if open { customOpenKeys.insert(key) } else { customOpenKeys.remove(key) }
            }
        )
    }
}

/// Shared state seeding, validation, and encoding helpers for non-secret fields in `InlineAsk` and `FormSheet`.
enum AskSheetLogic {
    static func seedNonSecretState(
        fields: [Asker.Field],
        selectedByKey: inout [String: [String]],
        customByKey: inout [String: String],
        customOpenKeys: inout Set<String>,
        values: inout [String: String],
        usesSegmentedPicker: (Asker.Field) -> Bool
    ) {
        for field in fields where !field.secret {
            let optionValues = Set(field.effectiveOptions.map(\.value))
            switch field.effectiveKind {
            case .text:
                if values[field.key] == nil { values[field.key] = field.value }
                if customByKey[field.key] == nil { customByKey[field.key] = field.value }
            case .single:
                if usesSegmentedPicker(field) {
                    if values[field.key] == nil { values[field.key] = field.value }
                } else if selectedByKey[field.key] == nil && customByKey[field.key] == nil {
                    if !field.value.isEmpty {
                        if optionValues.contains(field.value) {
                            selectedByKey[field.key] = [field.value]
                        } else if field.allowCustom {
                            customByKey[field.key] = field.value
                            customOpenKeys.insert(field.key)
                        }
                    }
                }
            case .multi:
                if selectedByKey[field.key] == nil {
                    if !field.defaultSelections.isEmpty {
                        selectedByKey[field.key] = field.defaultSelections.filter { optionValues.contains($0) }
                    } else if !field.value.isEmpty, optionValues.contains(field.value) {
                        selectedByKey[field.key] = [field.value]
                    } else {
                        selectedByKey[field.key] = []
                    }
                }
            }
        }
    }

    static func response(
        for field: Asker.Field,
        selectedByKey: [String: [String]],
        customByKey: [String: String],
        customOpenKeys: Set<String>,
        textValues: [String: String]? = nil
    ) -> AskResponse {
        switch field.effectiveKind {
        case .text:
            let text = textValues?[field.key] ?? customByKey[field.key]
            return AskResponse(selected: [], customText: text)
        case .single:
            if customOpenKeys.contains(field.key) {
                return AskResponse(selected: [], customText: customByKey[field.key])
            }
            return AskResponse(selected: selectedByKey[field.key] ?? [], customText: nil)
        case .multi:
            let custom = customOpenKeys.contains(field.key) ? customByKey[field.key] : nil
            return AskResponse(selected: selectedByKey[field.key] ?? [], customText: custom)
        }
    }

    static func validatedNonSecretField(_ field: Asker.Field, response: AskResponse) -> AskResponse? {
        let question = field.askQuestion
        guard case .success(let validated) = AskUserRules.validate(response: response, for: question, enforceRequired: true) else {
            return nil
        }
        return validated
    }

    static func validateAllNonSecretFields(
        fields: [Asker.Field],
        responseProvider: (Asker.Field) -> AskResponse
    ) -> AskValidationError? {
        for field in fields where !field.secret {
            let response = responseProvider(field)
            if case .failure(let error) = AskUserRules.validate(response: response, for: field.askQuestion, enforceRequired: true) {
                return error
            }
        }
        return nil
    }

    static func activeInputError(
        for fields: [Asker.Field],
        responseProvider: (Asker.Field) -> AskResponse
    ) -> String? {
        for field in fields where !field.secret {
            let response = responseProvider(field)
            if case .failure(let error) = AskUserRules.validate(response: response, for: field.askQuestion, enforceRequired: true) {
                switch error {
                case .emptySelection:
                    continue
                case .tooFewSelections:
                    let hasCustom = !(response.customText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if response.selected.isEmpty && !hasCustom {
                        continue
                    }
                    return error.userMessage
                default:
                    return error.userMessage
                }
            }
        }
        return nil
    }

    static func encodedNonSecretField(_ field: Asker.Field, response: AskResponse) -> String {
        let question = field.askQuestion
        if case .success(let validated) = AskUserRules.validate(response: response, for: question, enforceRequired: true) {
            return AskUserRules.encodeResponse(validated, for: question)
        }
        return AskUserRules.encodeResponse(response, for: question)
    }
}

/// Reusable non-secret question control shared by `InlineAsk` and `FormSheet`.
struct AskFieldControl: View {
    let field: Asker.Field
    var showLabel: Bool = true
    var showOptional: Bool = true
    @Binding var selected: [String]
    @Binding var customText: String
    @Binding var isCustomOpen: Bool
    var limitWarning: Bool = false
    var onLimitHit: () -> Void = {}

    private var kind: AskFieldKind { field.effectiveKind }
    private var options: [AskOption] { field.effectiveOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if showLabel || kind == .multi || (showOptional && field.optionalBadge) {
                headerRow
            }
            if kind == .text {
                textFieldControl
            } else {
                AskOptionSelector(
                    kind: kind,
                    options: options,
                    allowCustom: field.allowCustom,
                    allowsEmpty: field.askQuestion.effectiveMinSelections == 0,
                    maxSelections: field.maxSelections,
                    placeholder: field.placeholder,
                    selected: $selected,
                    customText: $customText,
                    isCustomOpen: $isCustomOpen,
                    onLimitHit: onLimitHit
                )
            }
            if limitWarning, let max = field.maxSelections {
                Text(L.format("ask.maxReached", max))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.warn)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
            if showLabel {
                Text(field.label)
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(Ink.inkSoft)
            }
            if showOptional && (field.optionalBadge || (kind == .multi && !field.askQuestion.required)) {
                Text(L.t("ask.optional"))
                    .font(.system(size: Ink.Size.micro))
                    .foregroundStyle(Ink.inkFaint)
            }
            Spacer(minLength: 0)
            if kind == .multi {
                Text(multiHintText)
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(selectedOrCustomCount > 0 ? Ink.accent : Ink.inkFaint)
            }
        }
    }

    private var selectedOrCustomCount: Int {
        let customNonEmpty = isCustomOpen && !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return selected.count + (customNonEmpty ? 1 : 0)
    }

    private var multiHintText: String {
        let count = selectedOrCustomCount
        let countLabel = count > 0 ? L.format("ask.selectedCount", count) : ""
        let ruleLabel: String
        let minVal = field.askQuestion.answeredMinSelections
        if let max = field.maxSelections, minVal > 0 {
            ruleLabel = L.format("ask.rangeHint", minVal, max)
        } else if minVal > 0 {
            ruleLabel = L.format("ask.minHint", minVal)
        } else if let max = field.maxSelections {
            ruleLabel = L.format("ask.maxHint", max)
        } else {
            ruleLabel = L.t("ask.multiHint")
        }
        return countLabel.isEmpty ? ruleLabel : "\(ruleLabel) · \(countLabel)"
    }

    private var textFieldControl: some View {
        TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: $customText, axis: .vertical)
            .font(.system(size: Ink.Size.sub))
            .foregroundStyle(Ink.ink)
            .lineLimit(1...4)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(Ink.paper, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.rule, lineWidth: 0.5))
    }
}

/// Option list supporting capsule chips or detailed rows, single/multi checkmarks, recommended badge, and inline custom input.
struct AskOptionSelector: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let kind: AskFieldKind
    let options: [AskOption]
    let allowCustom: Bool
    var allowsEmpty: Bool = false
    let maxSelections: Int?
    let placeholder: String
    @Binding var selected: [String]
    @Binding var customText: String
    @Binding var isCustomOpen: Bool
    var onLimitHit: () -> Void
    @State private var focusCustomOnAppear = false

    private var usesDetailedRows: Bool {
        typeSize.isAccessibilitySize || options.contains { !$0.detail.isEmpty || $0.label.count > 22 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if usesDetailedRows {
                detailedRows
            } else {
                wrappedChips
            }
            if allowCustom && isCustomOpen {
                AskCustomInputBox(
                    placeholder: placeholder.isEmpty ? L.t("ask.customPlaceholder") : placeholder,
                    autoFocus: focusCustomOnAppear,
                    text: $customText,
                    onConfirm: {
                        Haptics.tick(0.4)
                        focusCustomOnAppear = false
                        if customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            withAnimation(Ink.Motion.press) { isCustomOpen = false }
                        }
                    },
                    onClear: {
                        Haptics.light()
                        focusCustomOnAppear = false
                        customText = ""
                        withAnimation(Ink.Motion.press) { isCustomOpen = false }
                    }
                )
            }
        }
    }

    private var wrappedChips: some View {
        WrapLayout(spacing: Ink.Space.s) {
            ForEach(options) { option in
                AskOptionChip(
                    option: option,
                    isMulti: kind == .multi,
                    isSelected: isSelected(option.value)
                ) {
                    toggleOption(option.value)
                }
            }
            if allowCustom {
                customToggleChip
            }
        }
    }

    private var detailedRows: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            ForEach(options) { option in
                AskOptionRow(
                    option: option,
                    isMulti: kind == .multi,
                    isSelected: isSelected(option.value)
                ) {
                    toggleOption(option.value)
                }
            }
            if allowCustom {
                customToggleRow
            }
        }
    }

    private var customHasText: Bool {
        !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customChipActive: Bool {
        isCustomOpen || (kind == .multi && customHasText)
    }

    private var customToggleChip: some View {
        Button { toggleCustom() } label: {
            HStack(spacing: Ink.Space.xs) {
                Image(systemName: customChipActive && customHasText ? "checkmark" : "square.and.pencil")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                Text(L.t("ask.otherCustom"))
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(customChipActive ? Ink.paper : Ink.ink)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(customChipActive ? Ink.accent : Ink.mine, in: Capsule())
            .overlay(Capsule().strokeBorder(customChipActive ? Ink.accent : Ink.rule, lineWidth: 0.5))
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(L.t("ask.otherCustom"))
        .accessibilityValue(L.t(customChipActive ? "ask.selectedState" : "ask.unselectedState"))
        .accessibilityAddTraits(customChipActive ? .isSelected : [])
    }

    private var customToggleRow: some View {
        Button { toggleCustom() } label: {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: customChipActive ? (kind == .multi ? "checkmark.square.fill" : "checkmark.circle.fill") : "square.and.pencil")
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(customChipActive ? Ink.accent : Ink.inkFaint)
                Text(L.t("ask.otherCustom"))
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(customChipActive ? Ink.accentWash : Ink.mine, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .strokeBorder(customChipActive ? Ink.accent.opacity(0.6) : Ink.rule, lineWidth: customChipActive ? 1 : 0.5)
            )
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(L.t("ask.otherCustom"))
        .accessibilityValue(L.t(customChipActive ? "ask.selectedState" : "ask.unselectedState"))
        .accessibilityAddTraits(customChipActive ? .isSelected : [])
    }

    private func isSelected(_ value: String) -> Bool {
        if kind == .single && isCustomOpen { return false }
        return selected.contains(value)
    }

    private func toggleOption(_ value: String) {
        Haptics.tick(0.4)
        if kind == .single {
            focusCustomOnAppear = false
            isCustomOpen = false
            if allowsEmpty && selected == [value] {
                selected = []
            } else {
                selected = [value]
            }
            return
        }
        if let idx = selected.firstIndex(of: value) {
            selected.remove(at: idx)
            return
        }
        let customCount = (isCustomOpen && customHasText) ? 1 : 0
        if let maxSelections, selected.count + customCount >= maxSelections {
            if maxSelections == 1 {
                focusCustomOnAppear = false
                isCustomOpen = false
                selected = [value]
            } else {
                onLimitHit()
            }
            return
        }
        selected.append(value)
    }

    private func toggleCustom() {
        Haptics.tick(0.4)
        if kind == .single {
            withAnimation(Ink.Motion.press) {
                if isCustomOpen {
                    focusCustomOnAppear = false
                    isCustomOpen = false
                } else {
                    selected = []
                    focusCustomOnAppear = true
                    isCustomOpen = true
                }
            }
            return
        }
        if isCustomOpen {
            withAnimation(Ink.Motion.press) {
                focusCustomOnAppear = false
                isCustomOpen = false
                customText = ""
            }
        } else {
            if let maxSelections, selected.count >= maxSelections {
                if maxSelections == 1 {
                    selected = []
                } else {
                    onLimitHit()
                    return
                }
            }
            withAnimation(Ink.Motion.press) {
                focusCustomOnAppear = true
                isCustomOpen = true
            }
        }
    }
}

private struct AskOptionChip: View {
    let option: AskOption
    let isMulti: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Ink.Space.xs) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.micro, weight: .bold))
                } else if isMulti {
                    Image(systemName: "circle")
                        .font(.system(size: Ink.Size.micro))
                        .foregroundStyle(Ink.inkFaint)
                }
                Text(option.label)
                    .font(.system(size: Ink.Size.sub, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if option.recommended {
                    Text(L.t("ask.recommended"))
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(isSelected ? Ink.paper : Ink.accent)
                        .padding(.horizontal, Ink.Space.xs)
                        .padding(.vertical, 1)
                        .background(
                            isSelected ? Ink.paper.opacity(0.22) : Ink.accentWash,
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? Ink.paper : Ink.ink)
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(isSelected ? Ink.accent : Ink.mine, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Ink.accent : Ink.rule, lineWidth: 0.5))
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(option.recommended ? "\(option.label)，\(L.t("ask.recommended"))" : option.label)
        .accessibilityValue(L.t(isSelected ? "ask.selectedState" : "ask.unselectedState"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AskOptionRow: View {
    let option: AskOption
    let isMulti: Bool
    let isSelected: Bool
    let action: () -> Void

    private var checkSymbol: String {
        if isMulti {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Ink.Space.s) {
                Image(systemName: checkSymbol)
                    .font(.system(size: Ink.Size.sub))
                    .foregroundStyle(isSelected ? Ink.accent : Ink.inkFaint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    HStack(spacing: Ink.Space.xs) {
                        Text(option.label)
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(Ink.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if option.recommended {
                            Text(L.t("ask.recommended"))
                                .font(.system(size: Ink.Size.micro, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .padding(.horizontal, Ink.Space.xs)
                                .padding(.vertical, 1)
                                .background(Ink.accentWash, in: Capsule())
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.s)
            .background(isSelected ? Ink.accentWash : Ink.mine, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .strokeBorder(isSelected ? Ink.accent.opacity(0.6) : Ink.rule, lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel(option.detail.isEmpty ? option.label : "\(option.label)，\(option.detail)")
        .accessibilityValue(L.t(isSelected ? "ask.selectedState" : "ask.unselectedState"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AskCustomInputBox: View {
    let placeholder: String
    let autoFocus: Bool
    @Binding var text: String
    let onConfirm: () -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Ink.Space.s) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: Ink.Size.sub))
                .foregroundStyle(Ink.ink)
                .lineLimit(1...3)
                .focused($focused)
            if hasText {
                Button {
                    focused = false
                    onConfirm()
                } label: {
                    Text(L.t("actions.confirm"))
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.xs)
                        .background(Ink.accent, in: Capsule())
                }
                .buttonStyle(PressStyle(haptic: false))
            } else {
                Button {
                    focused = false
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.inkFaint)
                }
                .buttonStyle(TapStyle(grow: 6))
                .accessibilityLabel(L.t("actions.close"))
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .background(Ink.paper, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                .strokeBorder(Ink.accent.opacity(0.45), lineWidth: 0.75)
        )
        .onAppear {
            if autoFocus { focused = true }
        }
    }
}

/// Lays its children out in rows, wrapping when a row is full and constraining wide chips to the container width.
struct WrapLayout: Layout {
    var spacing: CGFloat = Ink.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let childProposal = maxWidth.isFinite ? ProposedViewSize(width: maxWidth, height: nil) : .unspecified
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let measured = view.sizeThatFits(childProposal)
            let clampedWidth = maxWidth.isFinite ? min(measured.width, maxWidth) : measured.width
            if x > 0, x + clampedWidth > maxWidth {
                y += row + spacing
                x = 0
                row = 0
            }
            x += clampedWidth + spacing
            row = max(row, measured.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let childProposal = ProposedViewSize(width: maxWidth, height: nil)
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let measured = view.sizeThatFits(childProposal)
            let clampedWidth = min(measured.width, maxWidth)
            if x > bounds.minX, x + clampedWidth > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: clampedWidth, height: measured.height)
            )
            x += clampedWidth + spacing
            row = max(row, measured.height)
        }
    }
}

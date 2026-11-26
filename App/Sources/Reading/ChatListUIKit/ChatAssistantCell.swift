import AgentKit
import Prose
import SwiftUI
import UIKit

/// Production UIKit cell for assistant messages (`.bot`) and live streaming prose (`.liveProse`).
/// Uses pooled native views for prose, code, tables, math, thoughts, and footer actions, with zero-flicker
/// in-place updates and cross-paragraph selection preservation.
@MainActor
final class ChatAssistantCell: UICollectionViewCell {
    static let reuseID = "ChatAssistantCell"

    struct Callbacks {
        var onToggleThinking: () -> Void = {}
        var onTogglePulse: () -> Void = {}
        var onToggleLookback: () -> Void = {}
        var onToggleCodeFold: (Int) -> Void = { _ in }
        var onBlockHeightChanged: (String, String, CGFloat) -> Void = { _, _, _ in }
        var onFormulaHeightResolved: (String, String, CGFloat) -> Void = { _, _, _ in }
        var onSelectionChanged: (UUID, Bool) -> Void = { _, _ in }
        var onQuoteExcerpt: (String) -> Void = { _ in }
        var onSpeakExcerpt: (String) -> Void = { _ in }
        var onSaveNoteExcerpt: (String, String) -> Void = { _, _ in }
        var onShareText: (String) -> Void = { _ in }
        var onRevealFrame: (Bool) -> Void = { _ in }
    }

    private let litBackdrop = UIView()
    private let timeGapLabel = UILabel()
    private let speakerAvatar = ChatPetAvatarView()
    private let speakerLabel = UILabel()

    private let thinkingHeader = UIButton(type: .custom)
    private let thinkingBrain = UIImageView()
    private let thinkingLabel = UILabel()
    private let thinkingChevron = UIImageView()
    private let thinkingStripe = UIView()
    private var thinkingTextView: ChatRichTextView?

    private let pulseHeader = UIButton(type: .custom)
    private let pulseSymbol = UILabel()
    private let pulseLabel = UILabel()
    private let pulseChevron = UIImageView()
    private let pulseCard = UIView()
    private var pulseTextView: ChatRichTextView?

    private let lookbackButton = UIButton(type: .custom)
    private let lookbackIcon = UIImageView()
    private let lookbackLabel = UILabel()

    private var richTextViews: [ChatRichTextView] = []
    private var codeBlockViews: [ChatCodeBlockView] = []
    private var tableBlockViews: [ChatTableBlockView] = []
    private var formulaBlockViews: [ChatFormulaBlockView] = []
    private var fileCardBlockViews: [ChatFileCardsBlockView] = []
    private var pictureBlockViews: [ChatProsePictureView] = []

    private let sourcesPill = ChatSourcesPillView()
    private let continueButton = UIButton(type: .system)
    private let footerView = ChatBotFooterView()

    private weak var hostViewController: UIViewController?
    private var actions: ChatListActions?
    private var callbacks = Callbacks()

    private var ownerID = ""
    private var currentRow: ChatListRowItem?
    private var currentEntry: ChatLayoutCache.AssistantLayoutEntry?
    private var currentStyle: ChatListStyle?
    private var isThinkingExpanded = false
    private var isPulseExpanded = false
    private var isLookbackExpanded = false
    private var unfoldedSlices: Set<Int> = []
    private var isLiveStreamingOnly = false
    private var streamingGeneration = 0
    private var appliedContinueButtonSignature = ""
    private var appliedContinueThemeSignature = ""
    private var lastColorSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        litBackdrop.layer.cornerCurve = .continuous
        litBackdrop.isHidden = true
        contentView.addSubview(litBackdrop)

        timeGapLabel.textAlignment = .center
        timeGapLabel.isHidden = true
        contentView.addSubview(timeGapLabel)

        speakerAvatar.isHidden = true
        contentView.addSubview(speakerAvatar)

        speakerLabel.lineBreakMode = .byTruncatingTail
        speakerLabel.isHidden = true
        contentView.addSubview(speakerLabel)

        setupThinkingViews()
        setupPulseViews()
        setupLookbackViews()

        sourcesPill.isHidden = true
        contentView.addSubview(sourcesPill)

        setupContinueButton()

        footerView.isHidden = true
        contentView.addSubview(footerView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatAssistantCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    private func setupThinkingViews() {
        thinkingBrain.image = UIImage(systemName: "brain", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .medium))
        thinkingBrain.contentMode = .scaleAspectFit
        thinkingLabel.lineBreakMode = .byTruncatingTail
        thinkingChevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        thinkingChevron.contentMode = .scaleAspectFit

        thinkingHeader.addSubview(thinkingBrain)
        thinkingHeader.addSubview(thinkingLabel)
        thinkingHeader.addSubview(thinkingChevron)
        thinkingHeader.addAction(UIAction { [weak self] _ in
            Haptics.tick(0.4)
            self?.callbacks.onToggleThinking()
        }, for: .touchUpInside)
        thinkingHeader.isHidden = true
        contentView.addSubview(thinkingHeader)

        thinkingStripe.layer.cornerRadius = 1
        thinkingStripe.isHidden = true
        contentView.addSubview(thinkingStripe)
    }

    private func setupPulseViews() {
        pulseSymbol.textAlignment = .center
        pulseLabel.lineBreakMode = .byTruncatingTail
        pulseChevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        pulseChevron.contentMode = .scaleAspectFit

        pulseHeader.addSubview(pulseSymbol)
        pulseHeader.addSubview(pulseLabel)
        pulseHeader.addSubview(pulseChevron)
        pulseHeader.addAction(UIAction { [weak self] _ in
            Haptics.tick(0.4)
            self?.callbacks.onTogglePulse()
        }, for: .touchUpInside)
        pulseHeader.isHidden = true
        contentView.addSubview(pulseHeader)

        pulseCard.layer.cornerCurve = .continuous
        pulseCard.isHidden = true
        contentView.addSubview(pulseCard)
    }

    private func setupLookbackViews() {
        lookbackIcon.image = UIImage(systemName: "arrow.uturn.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        lookbackIcon.contentMode = .scaleAspectFit
        lookbackLabel.numberOfLines = 1
        lookbackLabel.lineBreakMode = .byTruncatingTail

        lookbackButton.addSubview(lookbackIcon)
        lookbackButton.addSubview(lookbackLabel)
        lookbackButton.addAction(UIAction { [weak self] _ in
            Haptics.tick(0.4)
            self?.callbacks.onToggleLookback()
        }, for: .touchUpInside)
        lookbackButton.isHidden = true
        contentView.addSubview(lookbackButton)
    }

    private func setupContinueButton() {
        continueButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.actions?.bridge.onContinueStepLimit()
        }, for: .touchUpInside)
        continueButton.isHidden = true
        contentView.addSubview(continueButton)
    }

    private func applyContinueButtonTypographyIfNeeded(style: ChatListStyle) {
        let title = L.t("chat.continueTask")
        let sig = "\(title)|\(style.uiScale)|\(style.contentSizeCategory)"
        guard appliedContinueButtonSignature != sig || continueButton.configuration == nil else { return }
        appliedContinueButtonSignature = sig
        appliedContinueThemeSignature = ""
        lastColorSignature = ""
        var cfg = continueButton.configuration ?? UIButton.Configuration.filled()
        cfg.title = title
        cfg.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        cfg.imagePadding = Ink.Space.xs
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Ink.Space.l, bottom: 6, trailing: Ink.Space.l)
        cfg.cornerStyle = .capsule
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
            return copy
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        continueButton.configuration = cfg
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ownerID = ""
        currentRow = nil
        currentEntry = nil
        isLiveStreamingOnly = false
        hostViewController = nil
        actions = nil
        callbacks = Callbacks()

        thinkingTextView?.setRevealVisible(false)
        thinkingTextView?.resetForReuse()
        thinkingTextView?.isHidden = true
        pulseTextView?.setRevealVisible(false)
        pulseTextView?.resetForReuse()
        pulseTextView?.isHidden = true
        richTextViews.forEach {
            $0.setRevealVisible(false)
            $0.resetForReuse()
            $0.isHidden = true
        }
        codeBlockViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        tableBlockViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        formulaBlockViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        fileCardBlockViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        pictureBlockViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        sourcesPill.resetForReuse()
        footerView.resetForReuse()
    }

    func activeSelectionOwnerIDs() -> [UUID] {
        var ids: [UUID] = []
        if let thinkingTextView, !thinkingTextView.isHidden, thinkingTextView.selectedRange.length > 0 {
            ids.append(thinkingTextView.selectionOwnerID)
        }
        if let pulseTextView, !pulseTextView.isHidden, pulseTextView.selectedRange.length > 0 {
            ids.append(pulseTextView.selectionOwnerID)
        }
        for tv in richTextViews where !tv.isHidden && tv.selectedRange.length > 0 {
            ids.append(tv.selectionOwnerID)
        }
        for cb in codeBlockViews where !cb.isHidden && cb.hasActiveSelection {
            ids.append(cb.selectionOwnerID)
        }
        return ids
    }

    func currentProseSelectionSnapshot() -> ChatProseSelectionSnapshot? {
        for (idx, tv) in richTextViews.enumerated() where !tv.isHidden {
            if let snap = tv.currentSelectionSnapshot() {
                return ChatProseSelectionSnapshot(
                    richTextIndex: idx,
                    range: snap.range,
                    substring: snap.substring
                )
            }
        }
        return nil
    }

    func clearAllSelections() {
        thinkingTextView?.clearSelectionIfNeeded()
        pulseTextView?.clearSelectionIfNeeded()
        richTextViews.forEach { $0.clearSelectionIfNeeded() }
        codeBlockViews.forEach { $0.clearSelection() }
    }

    private enum SelectableTarget {
        case richText(ChatRichTextView)
        case codeBlock(ChatCodeBlockView)
    }

    private func firstSelectableTarget(in entry: ChatLayoutCache.AssistantLayoutEntry) -> SelectableTarget? {
        var rtIndex = 0
        var cbIndex = 0
        for measured in entry.slices {
            switch measured.slice {
            case .richText:
                if rtIndex < richTextViews.count {
                    let tv = richTextViews[rtIndex]
                    if !tv.isHidden && tv.hasSelectableText {
                        return .richText(tv)
                    }
                }
                rtIndex += 1
            case .code:
                if cbIndex < codeBlockViews.count {
                    let cb = codeBlockViews[cbIndex]
                    if !cb.isHidden && cb.hasSelectableText {
                        return .codeBlock(cb)
                    }
                }
                cbIndex += 1
            case .pictures(let words, _, _):
                if words != nil {
                    if rtIndex < richTextViews.count {
                        let tv = richTextViews[rtIndex]
                        if !tv.isHidden && tv.hasSelectableText {
                            return .richText(tv)
                        }
                    }
                    rtIndex += 1
                }
            case .table, .math, .fileCards:
                break
            }
        }
        if let thinkingTextView, !thinkingTextView.isHidden && thinkingTextView.hasSelectableText {
            return .richText(thinkingTextView)
        }
        if let pulseTextView, !pulseTextView.isHidden && pulseTextView.hasSelectableText {
            return .richText(pulseTextView)
        }
        return nil
    }

    private func hasAnySelectableText(entry: ChatLayoutCache.AssistantLayoutEntry) -> Bool {
        firstSelectableTarget(in: entry) != nil
    }

    @discardableResult
    func beginTextSelection() -> Bool {
        guard let entry = currentEntry, let target = firstSelectableTarget(in: entry) else {
            return false
        }
        switch target {
        case .richText(let tv):
            return tv.activateSelectionAll()
        case .codeBlock(let cb):
            return cb.beginTextSelection()
        }
    }

    var latestFooterOwnerID: String? {
        guard let row = currentRow, row.isLatestBot, let entry = currentEntry, entry.hasFooter else { return nil }
        return row.line.id
    }

    func setRevealVisible(_ visible: Bool) {
        for tv in richTextViews where !tv.isHidden {
            tv.setRevealVisible(visible)
        }
    }

    var hasPaintedLiveTail: Bool {
        richTextViews.contains { !$0.isHidden && $0.hasPaintedLiveTail }
    }

    func revealedLineBottom(in view: UIView) -> CGFloat? {
        for textView in richTextViews.reversed() where !textView.isHidden {
            if let bottom = textView.revealedLineBottom, textView.bounds.height > 0 {
                return textView.convert(CGPoint(x: 0, y: bottom), to: view).y
            }
        }
        return nil
    }

    func captureRevealHandoff() -> ChatRevealHandoff? {
        for tv in richTextViews.reversed() where !tv.isHidden {
            if let handoff = tv.captureRevealHandoff() {
                return handoff
            }
        }
        return nil
    }

    func footerActionsRectInWindow() -> CGRect {
        guard !footerView.isHidden else { return .null }
        return footerView.actionsRectInWindow()
    }

    func configure(
        row: ChatListRowItem,
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle,
        expandedThinking: Bool,
        expandedPulse: Bool,
        expandedLookback: Bool,
        unfoldedSlices: Set<Int>,
        hostViewController: UIViewController?,
        actions: ChatListActions,
        callbacks: Callbacks,
        transferredSelection: ChatProseSelectionSnapshot? = nil,
        transferredReveal: ChatRevealHandoff? = nil
    ) {
        self.ownerID = row.line.id
        self.isLiveStreamingOnly = false
        self.currentRow = row
        self.currentEntry = entry
        self.currentStyle = style
        self.isThinkingExpanded = expandedThinking
        self.isPulseExpanded = expandedPulse
        self.isLookbackExpanded = expandedLookback
        self.unfoldedSlices = unfoldedSlices
        self.hostViewController = hostViewController
        self.actions = actions
        self.callbacks = callbacks

        applySettledContents(
            row: row,
            entry: entry,
            style: style,
            transferredSelection: transferredSelection,
            transferredReveal: transferredReveal
        )
    }

    func configureLiveStreaming(
        generation: Int,
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle,
        hostViewController: UIViewController?,
        actions: ChatListActions,
        callbacks: Callbacks
    ) {
        self.ownerID = "streaming-\(generation)"
        self.isLiveStreamingOnly = true
        self.streamingGeneration = generation
        self.currentRow = nil
        self.currentEntry = entry
        self.currentStyle = style
        self.isThinkingExpanded = false
        self.isPulseExpanded = false
        self.isLookbackExpanded = false
        self.unfoldedSlices = []
        self.hostViewController = hostViewController
        self.actions = actions
        self.callbacks = callbacks

        litBackdrop.isHidden = true
        timeGapLabel.isHidden = true
        speakerAvatar.isHidden = true
        speakerLabel.isHidden = true
        thinkingHeader.isHidden = true
        thinkingStripe.isHidden = true
        thinkingTextView?.isHidden = true
        thinkingTextView?.resetForReuse()
        pulseHeader.isHidden = true
        pulseCard.isHidden = true
        pulseTextView?.isHidden = true
        pulseTextView?.resetForReuse()
        lookbackButton.isHidden = true
        sourcesPill.isHidden = true
        continueButton.isHidden = true
        footerView.isHidden = true

        applySlices(entry: entry, style: style, lineID: ownerID, transferredSelection: nil, transferredReveal: nil)
        refreshColors()
        setNeedsLayout()
    }

    func updateLiveStreamingInPlace(entry: ChatLayoutCache.AssistantLayoutEntry, style: ChatListStyle) {
        guard isLiveStreamingOnly else { return }
        self.currentEntry = entry
        self.currentStyle = style
        applySlices(entry: entry, style: style, lineID: ownerID, transferredSelection: nil, transferredReveal: nil)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func updateSettledInPlace(
        row: ChatListRowItem,
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle,
        expandedThinking: Bool,
        expandedPulse: Bool,
        expandedLookback: Bool,
        unfoldedSlices: Set<Int>,
        transferredReveal: ChatRevealHandoff? = nil
    ) {
        guard !isLiveStreamingOnly, ownerID == row.line.id else { return }
        self.currentRow = row
        self.currentEntry = entry
        self.currentStyle = style
        self.isThinkingExpanded = expandedThinking
        self.isPulseExpanded = expandedPulse
        self.isLookbackExpanded = expandedLookback
        self.unfoldedSlices = unfoldedSlices
        applySettledContents(
            row: row,
            entry: entry,
            style: style,
            transferredSelection: nil,
            transferredReveal: transferredReveal
        )
        layoutIfNeeded()
    }

    private func applySettledContents(
        row: ChatListRowItem,
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle,
        transferredSelection: ChatProseSelectionSnapshot?,
        transferredReveal: ChatRevealHandoff?
    ) {
        litBackdrop.isHidden = !row.lit

        if entry.timeGapHeight > 0, let gap = row.timeGap {
            timeGapLabel.isHidden = false
            timeGapLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            timeGapLabel.text = gap
        } else {
            timeGapLabel.isHidden = true
        }

        if entry.speakerHeight > 0 {
            speakerAvatar.isHidden = false
            speakerLabel.isHidden = false
            let wash = row.speakerBot.map { Ink.wash(for: $0) }
            speakerAvatar.configure(bot: row.speakerBot, state: "idle", wash: wash, avatar: true)
            speakerLabel.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .semibold)
            speakerLabel.text = row.speakerTitle
        } else {
            speakerAvatar.isHidden = true
            speakerLabel.isHidden = true
        }

        configureThinking(row: row, entry: entry, style: style)
        configurePulse(row: row, entry: entry, style: style)
        configureLookback(row: row, entry: entry)

        applySlices(
            entry: entry,
            style: style,
            lineID: row.line.id,
            transferredSelection: transferredSelection,
            transferredReveal: transferredReveal
        )

        if entry.hasSources, let meta = row.lineMeta {
            sourcesPill.isHidden = false
            sourcesPill.hostViewController = hostViewController
            sourcesPill.onOpenURL = { [weak actions] url in
                actions?.bridge.onOpenURL(url)
            }
            sourcesPill.configure(urls: meta.urls, titles: meta.titles)
        } else {
            sourcesPill.isHidden = true
        }

        if entry.hasContinueButton {
            applyContinueButtonTypographyIfNeeded(style: style)
            continueButton.isHidden = false
        } else {
            continueButton.isHidden = true
        }

        if entry.hasFooter {
            footerView.isHidden = false
            footerView.onCopy = { [weak actions] in
                UIPasteboard.general.string = row.line.text
                Haptics.tick(0.5)
                actions?.bridge.onSay("复制好了。")
            }
            footerView.onSelectText = { [weak self] in
                self?.beginTextSelection()
            }
            footerView.onRedo = { [weak actions] in
                actions?.bridge.onRedo()
            }
            footerView.onSpeak = { [weak actions] in
                actions?.bridge.onSpeak(row.line.text)
            }
            footerView.onQuote = { [weak actions] in
                actions?.bridge.onQuote(row.line.id, row.line.text)
            }
            footerView.onSaveNote = { [weak actions] in
                actions?.bridge.onSaveNote(row.line.id, row.line.text)
            }
            footerView.onLongNote = { [weak actions] in
                actions?.bridge.onLongNote(row.line.id, row.line.text)
            }
            footerView.onShare = { [weak self] in
                self?.callbacks.onShareText(row.line.text)
            }
            footerView.onFork = { [weak actions] in
                actions?.bridge.onFork(row.line)
            }
            footerView.configure(row: row, showsSelectText: hasAnySelectableText(entry: entry))
        } else {
            footerView.isHidden = true
        }

        refreshColors()
        setNeedsLayout()
    }

    private func ensureThinkingTextView() -> ChatRichTextView {
        if let existing = thinkingTextView { return existing }
        let tv = ChatRichTextView()
        contentView.addSubview(tv)
        thinkingTextView = tv
        return tv
    }

    private func ensurePulseTextView() -> ChatRichTextView {
        if let existing = pulseTextView { return existing }
        let tv = ChatRichTextView()
        pulseCard.addSubview(tv)
        pulseTextView = tv
        return tv
    }

    private func configureThinking(row: ChatListRowItem, entry: ChatLayoutCache.AssistantLayoutEntry, style: ChatListStyle) {
        guard let rendered = entry.thinkingText, let raw = row.line.reasoning else {
            thinkingHeader.isHidden = true
            thinkingStripe.isHidden = true
            thinkingTextView?.isHidden = true
            thinkingTextView?.resetForReuse()
            return
        }
        thinkingHeader.isHidden = false
        thinkingLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        thinkingLabel.text = Words.t("沉吟") + "了 \(raw.count) 字"
        thinkingHeader.accessibilityLabel = "思考了 \(raw.count) 字，点开看"
        thinkingChevron.transform = isThinkingExpanded ? CGAffineTransform(rotationAngle: .pi * 0.5) : .identity

        thinkingStripe.isHidden = !isThinkingExpanded
        if isThinkingExpanded {
            let tv = ensureThinkingTextView()
            tv.isHidden = false
            wireTextViewCallbacks(tv, lineID: row.line.id)
            tv.apply(ownerID: row.line.id + "#thinking", rendered: rendered, style: style)
        } else {
            thinkingTextView?.isHidden = true
            thinkingTextView?.resetForReuse()
        }
    }

    private func configurePulse(row: ChatListRowItem, entry: ChatLayoutCache.AssistantLayoutEntry, style: ChatListStyle) {
        guard let rendered = entry.pulseText, let raw = row.line.pulse else {
            pulseHeader.isHidden = true
            pulseCard.isHidden = true
            pulseTextView?.isHidden = true
            pulseTextView?.resetForReuse()
            return
        }
        let temper = Temper.of(row.speakerBot)
        let blockName = temper.blockName ?? "心绪"
        pulseHeader.isHidden = false
        pulseSymbol.font = UIFont.systemFont(ofSize: Ink.Size.small)
        pulseSymbol.text = temper.symbol
        pulseLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        pulseLabel.text = Pulse.vibe(raw).map { "\(blockName) · \($0)" } ?? blockName
        pulseHeader.accessibilityLabel = "\(blockName)，点开看"
        pulseChevron.transform = isPulseExpanded ? CGAffineTransform(rotationAngle: .pi * 0.5) : .identity

        pulseCard.isHidden = !isPulseExpanded
        if isPulseExpanded {
            let tv = ensurePulseTextView()
            tv.isHidden = false
            wireTextViewCallbacks(tv, lineID: row.line.id)
            tv.apply(ownerID: row.line.id + "#pulse", rendered: rendered, style: style)
        } else {
            pulseTextView?.isHidden = true
            pulseTextView?.resetForReuse()
        }
    }

    private func configureLookback(row: ChatListRowItem, entry: ChatLayoutCache.AssistantLayoutEntry) {
        guard entry.lookbackHeight > 0, let note = row.lookbackNote else {
            lookbackButton.isHidden = true
            return
        }
        lookbackButton.isHidden = false
        lookbackLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        lookbackLabel.numberOfLines = isLookbackExpanded ? 0 : 1
        lookbackLabel.text = "回望 · " + note
        lookbackButton.accessibilityLabel = "回望：" + note
    }

    private func wireTextViewCallbacks(_ tv: ChatRichTextView, lineID: String) {
        tv.onRevealFrame = { [weak self] complete in self?.callbacks.onRevealFrame(complete) }
        tv.onQuoteSelection = { [weak self] excerpt in
            self?.callbacks.onQuoteExcerpt(excerpt)
        }
        tv.onSaveNoteSelection = { [weak self] excerpt in
            self?.callbacks.onSaveNoteExcerpt(lineID, excerpt)
        }
        tv.onSpeakSelection = { [weak self] excerpt in
            self?.callbacks.onSpeakExcerpt(excerpt)
        }
        tv.onSelectionActiveChanged = { [weak self] uuid, active in
            self?.callbacks.onSelectionChanged(uuid, active)
        }
        tv.onLinkTapped = { [weak actions] url in
            actions?.bridge.onOpenURL(url)
        }
    }

    private func ensureRichTextView(at index: Int) -> ChatRichTextView {
        while richTextViews.count <= index {
            let tv = ChatRichTextView()
            contentView.addSubview(tv)
            richTextViews.append(tv)
        }
        return richTextViews[index]
    }

    private func ensureCodeBlockView(at index: Int) -> ChatCodeBlockView {
        while codeBlockViews.count <= index {
            let cb = ChatCodeBlockView()
            contentView.addSubview(cb)
            codeBlockViews.append(cb)
        }
        return codeBlockViews[index]
    }

    private func ensureTableBlockView(at index: Int) -> ChatTableBlockView {
        while tableBlockViews.count <= index {
            let tb = ChatTableBlockView()
            contentView.addSubview(tb)
            tableBlockViews.append(tb)
        }
        return tableBlockViews[index]
    }

    private func ensureFormulaBlockView(at index: Int) -> ChatFormulaBlockView {
        while formulaBlockViews.count <= index {
            let fb = ChatFormulaBlockView()
            contentView.addSubview(fb)
            formulaBlockViews.append(fb)
        }
        return formulaBlockViews[index]
    }

    private func ensureFileCardBlockView(at index: Int) -> ChatFileCardsBlockView {
        while fileCardBlockViews.count <= index {
            let fc = ChatFileCardsBlockView()
            contentView.addSubview(fc)
            fileCardBlockViews.append(fc)
        }
        return fileCardBlockViews[index]
    }

    private func ensurePictureBlockView(at index: Int) -> ChatProsePictureView {
        while pictureBlockViews.count <= index {
            let pb = ChatProsePictureView()
            contentView.addSubview(pb)
            pictureBlockViews.append(pb)
        }
        return pictureBlockViews[index]
    }

    private func applySlices(
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle,
        lineID: String,
        transferredSelection: ChatProseSelectionSnapshot?,
        transferredReveal: ChatRevealHandoff?
    ) {
        var rtIndex = 0
        var cbIndex = 0
        var tbIndex = 0
        var fbIndex = 0
        var fcIndex = 0
        var pbIndex = 0
        let widthKey = Int(((entry.contentWidth + style.metrics.spacePage * 2) * 2).rounded())
        let isLive = isLiveStreamingOnly || (currentRow?.isFreshWriting ?? false)
        let prevLiveHandoff: ChatRevealHandoff? = isLive ? captureRevealHandoff() : nil

        var totalRichTextCount = 0
        for measured in entry.slices {
            switch measured.slice {
            case .richText:
                totalRichTextCount += 1
            case .pictures(let words, _, _) where words != nil:
                totalRichTextCount += 1
            default:
                break
            }
        }
        let lastRichTextIndex = totalRichTextCount - 1

        func transferTuple(for idx: Int) -> (range: NSRange, substring: String)? {
            guard let snap = transferredSelection else { return nil }
            if snap.richTextIndex == idx { return (snap.range, snap.substring) }
            if snap.richTextIndex > lastRichTextIndex && idx == lastRichTextIndex {
                return (snap.range, snap.substring)
            }
            return nil
        }

        for (slicePos, measured) in entry.slices.enumerated() {
            switch measured.slice {
            case .richText(let rendered):
                let tv = ensureRichTextView(at: rtIndex)
                tv.isHidden = false
                wireTextViewCallbacks(tv, lineID: lineID)
                let isSliceLiveTail = isLive && (rendered.liveTailIndex != nil)
                let sliceRevealTransfer: ChatRevealHandoff?
                if isSliceLiveTail {
                    sliceRevealTransfer = (rtIndex == lastRichTextIndex) ? prevLiveHandoff : nil
                } else if !isLive && rtIndex == lastRichTextIndex {
                    sliceRevealTransfer = transferredReveal
                } else {
                    sliceRevealTransfer = nil
                }
                tv.apply(
                    ownerID: "\(lineID)#rt\(rtIndex)",
                    rendered: rendered,
                    style: style,
                    isLive: isLive,
                    isLiveTail: isSliceLiveTail,
                    transferredSelection: transferTuple(for: rtIndex),
                    transferredReveal: sliceRevealTransfer
                )
                rtIndex += 1

            case .code(let codeSlice, let sliceIndex):
                let cb = ensureCodeBlockView(at: cbIndex)
                cb.isHidden = false
                cb.onToggleFold = { [weak self] in
                    self?.callbacks.onToggleCodeFold(sliceIndex)
                }
                cb.onQuoteSelection = { [weak self] excerpt in
                    self?.callbacks.onQuoteExcerpt(excerpt)
                }
                cb.onSaveNoteSelection = { [weak self] excerpt in
                    self?.callbacks.onSaveNoteExcerpt(lineID, excerpt)
                }
                cb.onSpeakSelection = { [weak self] excerpt in
                    self?.callbacks.onSpeakExcerpt(excerpt)
                }
                cb.onSelectionActiveChanged = { [weak self] uuid, active in
                    self?.callbacks.onSelectionChanged(uuid, active)
                }
                cb.configure(slice: codeSlice, unfolded: unfoldedSlices.contains(sliceIndex), style: style)
                cbIndex += 1

            case .table(let tableSlice, _):
                let tb = ensureTableBlockView(at: tbIndex)
                tb.isHidden = false
                tb.onOpenURL = { [weak actions] url in
                    actions?.bridge.onOpenURL(url)
                }
                tb.configure(slice: tableSlice, style: style)
                tbIndex += 1

            case .math(let latex, let isLive, let sliceIndex):
                let fb = ensureFormulaBlockView(at: fbIndex)
                fb.isHidden = false
                let mathKey = "math|\(lineID)|\(sliceIndex)|\(widthKey)|\(style.styleKey)|\(fnv1a64(latex))"
                fb.configure(
                    latex: latex,
                    style: style,
                    streaming: isLive,
                    expectedHeight: measured.height,
                    onFormulaHeightResolved: { [weak self] exactHeight in
                        self?.callbacks.onFormulaHeightResolved(lineID, mathKey, exactHeight)
                    }
                )
                fbIndex += 1

            case .fileCards(let links, let sliceIndex):
                let fc = ensureFileCardBlockView(at: fcIndex)
                fc.isHidden = false
                let heightKey = "file|\(lineID)|\(sliceIndex)|\(widthKey)|\(style.styleKey)|\(links.map(\.path).joined(separator: "|"))"
                fc.configure(
                    links: links,
                    containerWidth: entry.contentWidth,
                    style: style,
                    expectedHeight: measured.height,
                    hostViewController: hostViewController,
                    actions: actions,
                    onHeightChanged: { [weak self] h in
                        self?.callbacks.onBlockHeightChanged(lineID, heightKey, h)
                    }
                )
                fcIndex += 1

            case .pictures(let words, let pics, let sliceIndex):
                if let words {
                    let tv = ensureRichTextView(at: rtIndex)
                    tv.isHidden = false
                    wireTextViewCallbacks(tv, lineID: lineID)
                    let picRevealTransfer = (!isLive && rtIndex == lastRichTextIndex) ? transferredReveal : nil
                    tv.apply(
                        ownerID: "\(lineID)#picwords\(slicePos)",
                        rendered: words,
                        style: style,
                        isLive: isLive,
                        isLiveTail: false,
                        transferredSelection: transferTuple(for: rtIndex),
                        transferredReveal: picRevealTransfer
                    )
                    rtIndex += 1
                }
                for (picIndex, pic) in pics.enumerated() {
                    let pb = ensurePictureBlockView(at: pbIndex)
                    pb.isHidden = false
                    let heightKey = "pic|\(lineID)|\(sliceIndex)|\(picIndex)|\(widthKey)|\(style.styleKey)|\(pic.source)"
                    let picExpectedH = picIndex < measured.pictureHeights.count ? measured.pictureHeights[picIndex] : 160
                    pb.configure(
                        source: pic.source,
                        label: pic.label,
                        containerWidth: entry.contentWidth,
                        scale: style.scale,
                        expectedHeight: picExpectedH,
                        hostViewController: hostViewController,
                        actions: actions,
                        onHeightChanged: { [weak self] h in
                            self?.callbacks.onBlockHeightChanged(lineID, heightKey, h)
                        }
                    )
                    pbIndex += 1
                }
            }
        }

        for idx in rtIndex..<richTextViews.count {
            richTextViews[idx].isHidden = true
            richTextViews[idx].resetForReuse()
        }
        for idx in cbIndex..<codeBlockViews.count {
            codeBlockViews[idx].isHidden = true
            codeBlockViews[idx].resetForReuse()
        }
        for idx in tbIndex..<tableBlockViews.count {
            tableBlockViews[idx].isHidden = true
            tableBlockViews[idx].resetForReuse()
        }
        for idx in fbIndex..<formulaBlockViews.count {
            formulaBlockViews[idx].isHidden = true
            formulaBlockViews[idx].resetForReuse()
        }
        for idx in fcIndex..<fileCardBlockViews.count {
            fileCardBlockViews[idx].isHidden = true
            fileCardBlockViews[idx].resetForReuse()
        }
        for idx in pbIndex..<pictureBlockViews.count {
            pictureBlockViews[idx].isHidden = true
            pictureBlockViews[idx].resetForReuse()
        }
    }

    private func refreshColors() {
        let theme = Theme.shared
        let colorSig = "\(traitCollection.userInterfaceStyle.rawValue)|\(theme.key)|\(theme.white)|\(theme.oled)|\(UIScale.factor)|\(!continueButton.isHidden)"
        guard colorSig != lastColorSignature else { return }
        lastColorSignature = colorSig

        litBackdrop.layer.cornerRadius = Ink.Radius.small
        litBackdrop.backgroundColor = UIColor(Ink.accentWash)

        timeGapLabel.textColor = UIColor(Ink.inkFaint)
        speakerLabel.textColor = UIColor(Ink.inkSoft)

        thinkingBrain.tintColor = UIColor(Ink.inkFaint)
        thinkingLabel.textColor = UIColor(Ink.inkFaint)
        thinkingChevron.tintColor = UIColor(Ink.inkFaint)
        thinkingStripe.backgroundColor = UIColor(Ink.rule)

        let pulseTint = UIColor(Ink.accent).withAlphaComponent(0.85)
        pulseSymbol.textColor = pulseTint
        pulseLabel.textColor = pulseTint
        pulseChevron.tintColor = pulseTint
        pulseCard.layer.cornerRadius = Ink.Radius.small
        pulseCard.backgroundColor = UIColor(Ink.accentWash)

        let lookbackTint = UIColor(Ink.accent).withAlphaComponent(0.85)
        lookbackIcon.tintColor = lookbackTint
        lookbackLabel.textColor = lookbackTint

        if !continueButton.isHidden {
            let themeSig = "\(Theme.shared.key)|\(traitCollection.userInterfaceStyle.rawValue)"
            if appliedContinueThemeSignature != themeSig, var cfg = continueButton.configuration {
                appliedContinueThemeSignature = themeSig
                cfg.baseForegroundColor = UIColor(Ink.accent)
                cfg.baseBackgroundColor = UIColor(Ink.accentWash)
                CATransaction.begin()
        CATransaction.setDisableActions(true)
        continueButton.configuration = cfg
        CATransaction.commit()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let entry = currentEntry, let style = currentStyle else { return }

        let pageMargin = Ink.Space.page
        let maxAvailable = max(120, contentView.bounds.width - pageMargin * 2)
        let contentWidth = min(maxAvailable, max(120, entry.contentWidth))
        let contentX = max(pageMargin, ((contentView.bounds.width - contentWidth) * 0.5).rounded())
        var y: CGFloat = 0

        if entry.timeGapHeight > 0 {
            timeGapLabel.frame = CGRect(x: contentX, y: y, width: contentWidth, height: entry.timeGapHeight)
            y += entry.timeGapHeight + ChatCellMetrics.timeGapBottomPad + ChatCellMetrics.sectionSpacing
        }

        if entry.speakerHeight > 0 {
            let size = entry.speakerHeight
            speakerAvatar.frame = CGRect(x: contentX, y: y, width: size, height: size)
            speakerLabel.frame = CGRect(
                x: contentX + size + ChatCellMetrics.speakerRowGap,
                y: y,
                width: max(40, contentWidth - size - ChatCellMetrics.speakerRowGap),
                height: size
            )
            y += size + ChatCellMetrics.sectionSpacing
        }

        var hasPriorBodyItem = false
        func advanceGap() {
            if hasPriorBodyItem { y += ChatCellMetrics.botBlockGap }
            hasPriorBodyItem = true
        }

        if entry.thinkingText != nil {
            advanceGap()
            layoutThinking(x: contentX, y: &y, width: contentWidth, entry: entry)
        }

        if entry.pulseText != nil {
            advanceGap()
            layoutPulse(x: contentX, y: &y, width: contentWidth, entry: entry)
        }

        if entry.lookbackHeight > 0 {
            advanceGap()
            lookbackButton.frame = CGRect(x: contentX, y: y, width: contentWidth, height: entry.lookbackHeight)
            let iconSize: CGFloat = 13
            lookbackIcon.frame = CGRect(x: 0, y: 2, width: iconSize, height: iconSize)
            lookbackLabel.frame = CGRect(x: iconSize + Ink.Space.s, y: 0, width: max(20, contentWidth - iconSize - Ink.Space.s), height: entry.lookbackHeight)
            y += entry.lookbackHeight
        }

        if !entry.slices.isEmpty {
            advanceGap()
            layoutSlices(x: contentX, y: &y, width: contentWidth, entry: entry, style: style)
        }

        if entry.hasSources {
            advanceGap()
            let pillSize = sourcesPill.sizeThatFits(CGSize(width: contentWidth, height: ChatCellMetrics.sourcesPillHeight))
            sourcesPill.frame = CGRect(x: contentX, y: y, width: pillSize.width, height: ChatCellMetrics.sourcesPillHeight)
            y += ChatCellMetrics.sourcesPillHeight
        }

        if entry.hasContinueButton {
            advanceGap()
            let fit = continueButton.sizeThatFits(CGSize(width: contentWidth, height: ChatCellMetrics.continueButtonHeight))
            continueButton.frame = CGRect(x: contentX, y: y, width: min(contentWidth, fit.width), height: ChatCellMetrics.continueButtonHeight)
            y += ChatCellMetrics.continueButtonHeight
        }

        if entry.hasFooter {
            advanceGap()
            footerView.frame = CGRect(x: contentX, y: y, width: contentWidth, height: ChatCellMetrics.footerHeight)
            y += ChatCellMetrics.footerHeight
        }

        if !litBackdrop.isHidden {
            let inset = Ink.Space.s
            litBackdrop.frame = CGRect(
                x: contentX - inset,
                y: -inset,
                width: contentWidth + inset * 2,
                height: max(20, y + inset * 2)
            )
        }
    }

    private func layoutThinking(x: CGFloat, y: inout CGFloat, width: CGFloat, entry: ChatLayoutCache.AssistantLayoutEntry) {
        let headerH = ChatCellMetrics.disclosureHeaderHeight
        thinkingHeader.frame = CGRect(x: x, y: y, width: width, height: headerH)
        let iconSize: CGFloat = 15
        thinkingBrain.frame = CGRect(x: 0, y: (headerH - iconSize) * 0.5, width: iconSize, height: iconSize)
        let textFit = thinkingLabel.sizeThatFits(CGSize(width: max(40, width - iconSize - 24), height: headerH))
        let labelX = iconSize + Ink.Space.s
        thinkingLabel.frame = CGRect(x: labelX, y: 0, width: ceil(textFit.width), height: headerH)
        thinkingChevron.frame = CGRect(x: thinkingLabel.frame.maxX + Ink.Space.s, y: (headerH - 11) * 0.5, width: 10, height: 11)
        y += headerH

        if isThinkingExpanded {
            y += ChatCellMetrics.disclosureGap
            let h = max(16, entry.thinkingTextHeight)
            thinkingStripe.frame = CGRect(x: x, y: y, width: 2, height: h)
            thinkingTextView?.frame = CGRect(x: x + Ink.Space.m, y: y, width: max(40, width - Ink.Space.m), height: h)
            y += h
        }
    }

    private func layoutPulse(x: CGFloat, y: inout CGFloat, width: CGFloat, entry: ChatLayoutCache.AssistantLayoutEntry) {
        let headerH = ChatCellMetrics.disclosureHeaderHeight
        pulseHeader.frame = CGRect(x: x, y: y, width: width, height: headerH)
        let symW: CGFloat = 16
        pulseSymbol.frame = CGRect(x: 0, y: 0, width: symW, height: headerH)
        let textFit = pulseLabel.sizeThatFits(CGSize(width: max(40, width - symW - 24), height: headerH))
        let labelX = symW + Ink.Space.s
        pulseLabel.frame = CGRect(x: labelX, y: 0, width: min(width - labelX - 18, ceil(textFit.width)), height: headerH)
        pulseChevron.frame = CGRect(x: pulseLabel.frame.maxX + Ink.Space.s, y: (headerH - 11) * 0.5, width: 10, height: 11)
        y += headerH

        if isPulseExpanded {
            y += ChatCellMetrics.disclosureGap
            let cardH = entry.pulseTextHeight + Ink.Space.s * 2
            pulseCard.frame = CGRect(x: x, y: y, width: width, height: cardH)
            pulseTextView?.frame = CGRect(x: Ink.Space.m, y: Ink.Space.s, width: max(40, width - Ink.Space.m * 2), height: entry.pulseTextHeight)
            y += cardH
        }
    }

    private func layoutSlices(
        x: CGFloat,
        y: inout CGFloat,
        width: CGFloat,
        entry: ChatLayoutCache.AssistantLayoutEntry,
        style: ChatListStyle
    ) {
        var rtIndex = 0
        var cbIndex = 0
        var tbIndex = 0
        var fbIndex = 0
        var fcIndex = 0
        var pbIndex = 0

        for (idx, measured) in entry.slices.enumerated() {
            if idx > 0 {
                if case .richText(let prev) = entry.slices[idx - 1].slice,
                   let explicitGap = prev.spacingAfter {
                    y += explicitGap
                } else {
                    y += style.paragraphGap
                }
            }
            switch measured.slice {
            case .richText:
                if rtIndex < richTextViews.count {
                    richTextViews[rtIndex].frame = CGRect(x: x, y: y, width: width, height: measured.height)
                    rtIndex += 1
                }
                y += measured.height

            case .code:
                if cbIndex < codeBlockViews.count {
                    codeBlockViews[cbIndex].frame = CGRect(x: x, y: y, width: width, height: measured.height)
                    cbIndex += 1
                }
                y += measured.height

            case .table:
                if tbIndex < tableBlockViews.count {
                    tableBlockViews[tbIndex].frame = CGRect(x: x, y: y, width: width, height: measured.height)
                    tbIndex += 1
                }
                y += measured.height

            case .math:
                if fbIndex < formulaBlockViews.count {
                    formulaBlockViews[fbIndex].frame = CGRect(x: x, y: y, width: width, height: measured.height)
                    fbIndex += 1
                }
                y += measured.height

            case .fileCards:
                if fcIndex < fileCardBlockViews.count {
                    fileCardBlockViews[fcIndex].frame = CGRect(x: x, y: y, width: width, height: measured.height)
                    fcIndex += 1
                }
                y += measured.height

            case .pictures(let words, let pics, _):
                var innerY = y
                if words != nil, rtIndex < richTextViews.count {
                    let wordsH = max(18, measured.height - measured.pictureHeights.reduce(0, +) - CGFloat(pics.count) * style.readingSize * 0.6)
                    richTextViews[rtIndex].frame = CGRect(x: x, y: innerY, width: width, height: wordsH)
                    rtIndex += 1
                    innerY += wordsH + style.readingSize * 0.6
                }
                for (picIdx, picH) in measured.pictureHeights.enumerated() {
                    if picIdx > 0 { innerY += style.readingSize * 0.6 }
                    if pbIndex < pictureBlockViews.count {
                        pictureBlockViews[pbIndex].frame = CGRect(x: x, y: innerY, width: width, height: picH)
                        pbIndex += 1
                    }
                    innerY += picH
                }
                y += measured.height
            }
        }
    }
}

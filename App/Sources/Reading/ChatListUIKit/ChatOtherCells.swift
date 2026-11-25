import AgentKit
import Craft
import SwiftUI
import UIKit

/// Pure UIKit cell for user messages: right-aligned glass bubble, attached photos, optional avatar,
/// selectable words on double-tap, and context menu (copy / quote / edit-resend).
@MainActor
final class ChatUserCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    static let reuseID = "ChatUserCell"

    var onQuoteExcerpt: ((String) -> Void)?
    var onSaveNoteExcerpt: ((String, String) -> Void)?
    var onSpeakExcerpt: ((String) -> Void)?
    var onSelectionChanged: ((UUID, Bool) -> Void)?

    private let litBackdrop = UIView()
    private let timeGapLabel = UILabel()
    private let meAvatar = ChatMeAvatarView()
    private var photoViews: [ChatRemotePhotoView] = []

    private let bubbleView = UIView()
    private let sheenLayer = CAGradientLayer()
    private let richTextView = ChatRichTextView()

    private var currentRow: ChatListRowItem?
    private var currentEntry: ChatLayoutCache.UserLayoutEntry?
    private var actions: ChatListActions?
    private var cachedShadowBounds: CGRect = .zero
    private var cachedShadowCornerRadius: CGFloat = -1

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

        meAvatar.isHidden = true
        contentView.addSubview(meAvatar)

        bubbleView.layer.cornerCurve = .continuous
        bubbleView.layer.shadowRadius = 10
        bubbleView.layer.shadowOffset = CGSize(width: 0, height: 3)
        bubbleView.layer.shadowOpacity = 1
        bubbleView.addInteraction(UIContextMenuInteraction(delegate: self))
        contentView.addSubview(bubbleView)

        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 0.5)
        bubbleView.layer.addSublayer(sheenLayer)
        bubbleView.addSubview(richTextView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatUserCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentRow = nil
        currentEntry = nil
        actions = nil
        richTextView.resetForReuse()
        photoViews.forEach { $0.resetForReuse(); $0.isHidden = true }
        onQuoteExcerpt = nil
        onSaveNoteExcerpt = nil
        onSpeakExcerpt = nil
        onSelectionChanged = nil
    }

    func activeSelectionOwnerIDs() -> [UUID] {
        richTextView.selectedRange.length > 0 ? [richTextView.selectionOwnerID] : []
    }

    func clearSelection() {
        richTextView.clearSelectionIfNeeded()
    }

    func photoHeroTarget(for attachmentID: String) -> ChatPhotoHeroTarget? {
        guard let row = currentRow,
              let idx = row.line.refs.firstIndex(of: attachmentID),
              idx < photoViews.count else { return nil }
        let pv = photoViews[idx]
        guard !pv.isHidden, let rect = pv.frameInWindow() else { return nil }
        return ChatPhotoHeroTarget(id: attachmentID, globalRect: rect, image: pv.currentImage)
    }

    func containsAttachment(_ attachmentID: String) -> Bool {
        currentRow?.line.refs.contains(attachmentID) == true
    }

    func configure(
        row: ChatListRowItem,
        entry: ChatLayoutCache.UserLayoutEntry,
        style: ChatListStyle,
        hostViewController: UIViewController?,
        actions: ChatListActions
    ) {
        self.currentRow = row
        self.currentEntry = entry
        self.actions = actions

        litBackdrop.isHidden = !row.lit

        if entry.timeGapHeight > 0, let gap = row.timeGap {
            timeGapLabel.isHidden = false
            timeGapLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            timeGapLabel.text = gap
        } else {
            timeGapLabel.isHidden = true
        }

        if row.faces && row.opens {
            meAvatar.isHidden = false
            meAvatar.hostViewController = hostViewController
            meAvatar.refreshDisplay()
        } else {
            meAvatar.isHidden = true
        }

        let refs = row.line.refs
        while photoViews.count < refs.count {
            let pv = ChatRemotePhotoView()
            contentView.addSubview(pv)
            photoViews.append(pv)
        }
        for (idx, pv) in photoViews.enumerated() {
            if idx < refs.count {
                pv.isHidden = false
                pv.onPrepareTouch = { [weak actions, weak pv] ref in
                    guard let actions, let pv, let rect = pv.frameInWindow() else { return }
                    actions.onPreparePhotoHero(ChatPhotoHeroTarget(id: ref, globalRect: rect, image: pv.currentImage))
                }
                pv.onCancelTouch = { [weak actions] ref in
                    guard let actions else { return }
                    if actions.bridge.activeViewingPhotoID != ref {
                        actions.onClearPhotoHero(ref)
                    }
                }
                pv.onTap = { [weak actions, weak pv] ref in
                    guard let actions else { return }
                    if let pv, let rect = pv.frameInWindow() {
                        let needsDefer = actions.currentPreparedHeroID() != ref
                        actions.onPreparePhotoHero(ChatPhotoHeroTarget(id: ref, globalRect: rect, image: pv.currentImage))
                        if needsDefer {
                            DispatchQueue.main.async {
                                actions.bridge.onViewPhoto(ref)
                            }
                            return
                        }
                    }
                    actions.bridge.onViewPhoto(ref)
                }
                pv.configure(chat: actions.chat, attachmentID: refs[idx])
            } else {
                pv.isHidden = true
                pv.resetForReuse()
            }
        }

        let hasText = !row.line.text.isEmpty && entry.bubbleHeight > 0
        bubbleView.isHidden = !hasText
        if hasText {
            richTextView.onQuoteSelection = { [weak self] excerpt in
                self?.onQuoteExcerpt?(excerpt)
            }
            richTextView.onSaveNoteSelection = { [weak self] excerpt in
                self?.onSaveNoteExcerpt?(row.line.id, excerpt)
            }
            richTextView.onSpeakSelection = { [weak self] excerpt in
                self?.onSpeakExcerpt?(excerpt)
            }
            richTextView.onSelectionActiveChanged = { [weak self] uuid, active in
                self?.onSelectionChanged?(uuid, active)
            }
            richTextView.apply(ownerID: row.line.id, rendered: entry.rendered, style: style)
        }

        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        litBackdrop.layer.cornerRadius = Ink.Radius.small
        litBackdrop.backgroundColor = UIColor(Ink.accentWash)
        timeGapLabel.textColor = UIColor(Ink.inkFaint)

        let editing = currentRow?.isEditing == true
        bubbleView.layer.cornerRadius = Ink.Radius.card
        bubbleView.backgroundColor = UIColor(editing ? Ink.accentWash : Ink.bubble)
        bubbleView.layer.borderWidth = editing ? 1.5 : 0.75
        bubbleView.layer.borderColor = UIColor(editing ? Ink.accent : Ink.rule).resolvedColor(with: traitCollection).cgColor
        bubbleView.layer.shadowColor = UIColor(Ink.bubbleShadow).resolvedColor(with: traitCollection).cgColor

        let topCG = UIColor(Ink.bubbleSheenTop).resolvedColor(with: traitCollection).cgColor
        let botCG = UIColor(Ink.bubbleSheenBottom).resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheenLayer.colors = [topCG, botCG]
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row = currentRow, let entry = currentEntry else { return }

        let pageMargin = Ink.Space.page
        let contentWidth = max(120, contentView.bounds.width - pageMargin * 2)
        var y: CGFloat = row.isFirst ? 0 : ChatCellMetrics.userTurnTopPad
        let contentStartY = y

        if entry.timeGapHeight > 0 {
            timeGapLabel.frame = CGRect(x: pageMargin, y: y, width: contentWidth, height: entry.timeGapHeight)
            y += entry.timeGapHeight + ChatCellMetrics.timeGapBottomPad + ChatCellMetrics.sectionSpacing
        }

        let avatarReserve: CGFloat = row.faces ? (ChatCellMetrics.faceSize + Ink.Space.s) : 0
        let rightEdge = contentView.bounds.width - pageMargin - avatarReserve

        if row.faces && row.opens {
            meAvatar.frame = CGRect(
                x: contentView.bounds.width - pageMargin - ChatCellMetrics.faceSize,
                y: y,
                width: ChatCellMetrics.faceSize,
                height: ChatCellMetrics.faceSize
            )
        }

        let rowTopY = y
        if entry.photosHeight > 0 {
            let size = ChatCellMetrics.photoSize
            let gap = ChatCellMetrics.photoSpacing
            let count = row.line.refs.count
            var px = rightEdge - CGFloat(count) * size - CGFloat(max(0, count - 1)) * gap
            for idx in 0..<count where idx < photoViews.count {
                photoViews[idx].frame = CGRect(x: px, y: y, width: size, height: size)
                px += size + gap
            }
            y += size
            if entry.bubbleHeight > 0 { y += Ink.Space.s }
        }

        if entry.bubbleHeight > 0 {
            let bubbleX = max(pageMargin, rightEdge - entry.bubbleWidth)
            bubbleView.frame = CGRect(x: bubbleX, y: y, width: entry.bubbleWidth, height: entry.bubbleHeight)
            let bubbleBounds = bubbleView.bounds
            let cornerRadius = Ink.Radius.card
            if !bubbleBounds.isEmpty,
               (cachedShadowBounds.size != bubbleBounds.size || abs(cachedShadowCornerRadius - cornerRadius) > 0.1) {
                cachedShadowBounds = bubbleBounds
                cachedShadowCornerRadius = cornerRadius
                bubbleView.layer.shadowPath = UIBezierPath(roundedRect: bubbleBounds, cornerRadius: cornerRadius).cgPath
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sheenLayer.frame = bubbleBounds
            sheenLayer.cornerRadius = cornerRadius
            CATransaction.commit()
            richTextView.frame = CGRect(
                x: ChatCellMetrics.userBubblePadH,
                y: ChatCellMetrics.userBubblePadV,
                width: entry.textWidth,
                height: entry.textHeight
            )
            y += entry.bubbleHeight
        }

        if row.faces && row.opens {
            y = max(y, rowTopY + ChatCellMetrics.faceSize)
        }

        if !litBackdrop.isHidden {
            let inset = Ink.Space.s
            litBackdrop.frame = CGRect(
                x: pageMargin - inset,
                y: contentStartY - inset,
                width: contentWidth + inset * 2,
                height: max(20, (y - contentStartY) + inset * 2)
            )
        }
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard richTextView.selectedRange.length == 0, let row = currentRow else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let copyAction = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = row.line.text
                Haptics.tick(0.5)
                self?.actions?.bridge.onSay("复制好了。")
            }
            let quoteAction = UIAction(title: "选字引用", image: UIImage(systemName: "text.quote")) { [weak self] _ in
                self?.actions?.bridge.onQuote(row.line.id, row.line.text)
            }
            let editAction = UIAction(title: "改了重发", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.actions?.bridge.onEdit(row.line.id, row.line.text)
            }
            return UIMenu(children: [copyAction, quoteAction, editAction])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        let params = UIPreviewParameters()
        params.visiblePath = UIBezierPath(roundedRect: bubbleView.bounds, cornerRadius: Ink.Radius.card)
        return UITargetedPreview(view: bubbleView, parameters: params)
    }
}

/// Pure UIKit cell for `.note` rows (fold dividers, `Explain.Advice` cards, and centered footnotes).
@MainActor
final class ChatNoteCell: UICollectionViewCell {
    static let reuseID = "ChatNoteCell"

    private enum Mode { case fold, advice, plain }

    private let foldButton = UIButton(type: .system)
    private let foldLeftRule = UIView()
    private let foldRightRule = UIView()
    private let foldLabel = UILabel()
    private let foldIcon = UIImageView()

    private let adviceCard = UIView()
    private let adviceIcon = UIImageView()
    private let adviceTitle = UILabel()
    private let adviceDetail = UILabel()
    private let adviceButton = UIButton(type: .system)

    private let plainLabel = UILabel()

    private var mode: Mode = .plain
    private var currentNext: Explain.Next?
    private var currentIsLatest = false
    private var currentEntry: ChatLayoutCache.NoteLayoutEntry?
    private var actions: ChatListActions?

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

        foldIcon.image = UIImage(systemName: "text.append", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small))
        foldIcon.contentMode = .scaleAspectFit
        foldLabel.lineBreakMode = .byTruncatingTail
        foldButton.addSubview(foldLeftRule)
        foldButton.addSubview(foldRightRule)
        foldButton.addSubview(foldIcon)
        foldButton.addSubview(foldLabel)
        foldButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.actions?.bridge.onOpenLeaves()
        }, for: .touchUpInside)
        contentView.addSubview(foldButton)

        adviceCard.layer.cornerCurve = .continuous
        adviceIcon.contentMode = .scaleAspectFit
        adviceTitle.numberOfLines = 0
        adviceDetail.numberOfLines = 0
        adviceButton.addAction(UIAction { [weak self] _ in
            guard let self, let next = self.currentNext else { return }
            Haptics.light()
            self.actions?.bridge.onAct(next)
        }, for: .touchUpInside)
        adviceCard.addSubview(adviceIcon)
        adviceCard.addSubview(adviceTitle)
        adviceCard.addSubview(adviceDetail)
        adviceCard.addSubview(adviceButton)
        contentView.addSubview(adviceCard)

        plainLabel.textAlignment = .center
        plainLabel.numberOfLines = 0
        contentView.addSubview(plainLabel)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatNoteCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        actions = nil
        currentNext = nil
        currentEntry = nil
    }

    func configure(row: ChatListRowItem, entry: ChatLayoutCache.NoteLayoutEntry, actions: ChatListActions) {
        self.actions = actions
        self.currentEntry = entry
        self.currentIsLatest = row.isLatestNote
        self.currentNext = row.line.next

        if row.line.fold {
            mode = .fold
            foldButton.isHidden = false
            adviceCard.isHidden = true
            plainLabel.isHidden = true
            foldLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            foldLabel.text = row.line.text
            foldButton.accessibilityLabel = row.line.text + "，点开看前情提要"
        } else if let next = row.line.next {
            mode = .advice
            foldButton.isHidden = true
            adviceCard.isHidden = false
            plainLabel.isHidden = true

            let parts = row.line.text.split(separator: "\n", maxSplits: 1).map(String.init)
            let advice = Explain.Advice(title: parts.first ?? row.line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
            adviceIcon.image = UIImage(
                systemName: next == .resume ? "pause.circle" : "exclamationmark.triangle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.sub, weight: .semibold)
            )
            adviceTitle.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
            adviceTitle.text = advice.displayTitle

            if !advice.detail.isEmpty {
                adviceDetail.isHidden = false
                adviceDetail.font = UIFont.systemFont(ofSize: Ink.Size.sub)
                adviceDetail.text = advice.detail
            } else {
                adviceDetail.isHidden = true
                adviceDetail.text = nil
            }

            if row.isLatestNote, let buttonText = advice.button {
                adviceButton.isHidden = false
                var cfg = UIButton.Configuration.filled()
                cfg.title = buttonText
                cfg.cornerStyle = .capsule
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Ink.Space.l, bottom: 6, trailing: Ink.Space.l)
                cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var copy = incoming
                    copy.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
                    return copy
                }
                adviceButton.configuration = cfg
            } else {
                adviceButton.isHidden = true
            }
        } else {
            mode = .plain
            foldButton.isHidden = true
            adviceCard.isHidden = true
            plainLabel.isHidden = false
            plainLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            plainLabel.text = row.line.text
        }
        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        foldLeftRule.backgroundColor = UIColor(Ink.rule)
        foldRightRule.backgroundColor = UIColor(Ink.rule)
        foldIcon.tintColor = UIColor(Ink.inkFaint)
        foldLabel.textColor = UIColor(Ink.inkFaint)
        plainLabel.textColor = UIColor(Ink.inkFaint)

        let isResume = currentNext == .resume
        adviceCard.layer.cornerRadius = Ink.Radius.card
        adviceCard.backgroundColor = isResume
            ? UIColor(Ink.paperRaised).withAlphaComponent(0.7)
            : UIColor(Ink.stop).withAlphaComponent(0.07)
        let titleColor = UIColor(isResume ? Ink.ink : Ink.stop)
        adviceIcon.tintColor = titleColor
        adviceTitle.textColor = titleColor
        adviceDetail.textColor = UIColor(Ink.inkSoft)

        var cfg = adviceButton.configuration
        cfg?.baseForegroundColor = UIColor(Ink.accent)
        cfg?.baseBackgroundColor = UIColor(Ink.accentWash)
        adviceButton.configuration = cfg
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pageMargin = Ink.Space.page
        let contentWidth = max(120, contentView.bounds.width - pageMargin * 2)

        switch mode {
        case .fold:
            let h: CGFloat = 36
            foldButton.frame = CGRect(x: pageMargin, y: 0, width: contentWidth, height: h)
            let iconW: CGFloat = 16
            let labelFit = foldLabel.sizeThatFits(CGSize(width: max(40, contentWidth - 60), height: h))
            let centerW = iconW + 6 + min(contentWidth - 60, ceil(labelFit.width))
            let ruleW = max(16, (contentWidth - centerW - Ink.Space.s * 2) * 0.5)
            foldLeftRule.frame = CGRect(x: 0, y: h * 0.5 - 0.5, width: ruleW, height: 1)
            foldIcon.frame = CGRect(x: ruleW + Ink.Space.s, y: (h - iconW) * 0.5, width: iconW, height: iconW)
            foldLabel.frame = CGRect(x: foldIcon.frame.maxX + 6, y: 0, width: ceil(labelFit.width), height: h)
            foldRightRule.frame = CGRect(x: contentWidth - ruleW, y: h * 0.5 - 0.5, width: ruleW, height: 1)

        case .advice:
            guard let entry = currentEntry else { return }
            let pad = Ink.Space.l
            let innerW = max(80, contentWidth - pad * 2)
            var y = pad
            let iconSide: CGFloat = 20
            adviceIcon.frame = CGRect(x: pad, y: y + 1, width: iconSide, height: iconSide)
            adviceTitle.frame = CGRect(x: pad + iconSide + Ink.Space.s, y: y, width: max(40, innerW - iconSide - Ink.Space.s), height: entry.titleHeight)
            y += entry.titleHeight

            if !adviceDetail.isHidden {
                y += Ink.Space.s
                adviceDetail.frame = CGRect(x: pad, y: y, width: innerW, height: entry.detailHeight)
                y += entry.detailHeight
            }

            if !adviceButton.isHidden {
                y += Ink.Space.s + Ink.Space.xs
                let fit = adviceButton.sizeThatFits(CGSize(width: innerW, height: 34))
                adviceButton.frame = CGRect(x: pad, y: y, width: min(innerW, fit.width), height: 34)
                y += 34
            }
            adviceCard.frame = CGRect(x: pageMargin, y: 0, width: contentWidth, height: y + pad)

        case .plain:
            let h = currentEntry?.titleHeight ?? 20
            plainLabel.frame = CGRect(x: pageMargin, y: 0, width: contentWidth, height: h)
        }
    }
}

/// Pure UIKit `"更早的"` upward pagination button cell.
@MainActor
final class ChatEarlierButtonCell: UICollectionViewCell {
    static let reuseID = "ChatEarlierButtonCell"

    var onLoadEarlier: (() -> Void)?

    private let button = UIButton(type: .system)

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

        applyButtonConfiguration()
        button.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.onLoadEarlier?()
        }, for: .touchUpInside)
        contentView.addSubview(button)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatEarlierButtonCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    func configure(onLoadEarlier: @escaping () -> Void) {
        self.onLoadEarlier = onLoadEarlier
        refreshTypography()
        refreshColors()
    }

    func refreshTypography() {
        applyButtonConfiguration()
        setNeedsLayout()
    }

    private func applyButtonConfiguration() {
        var cfg = button.configuration ?? UIButton.Configuration.plain()
        cfg.title = L.t("chat.earlier")
        cfg.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .medium))
        cfg.imagePadding = Ink.Space.xs
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .medium)
            return copy
        }
        button.configuration = cfg
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onLoadEarlier = nil
    }

    private func refreshColors() {
        button.tintColor = UIColor(Ink.inkSoft)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = Ink.Space.page
        button.frame = CGRect(x: margin, y: 0, width: max(120, contentView.bounds.width - margin * 2), height: 36)
    }
}

/// Live streaming `PulseBox` cell (`stream.pulse` before reply text starts).
@MainActor
final class ChatLivePulseCell: UICollectionViewCell {
    static let reuseID = "ChatLivePulseCell"

    private let symbolLabel = UILabel()
    private let titleLabel = UILabel()
    private let cardView = UIView()
    private let textView = ChatRichTextView()
    private var currentEntry: ChatLayoutCache.LiveTextEntry?

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

        symbolLabel.textAlignment = .center
        contentView.addSubview(symbolLabel)
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        cardView.layer.cornerCurve = .continuous
        contentView.addSubview(cardView)
        cardView.addSubview(textView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatLivePulseCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.resetForReuse()
        currentEntry = nil
    }

    func configure(
        text: String,
        temper: Temper,
        entry: ChatLayoutCache.LiveTextEntry,
        style: ChatListStyle,
        onSelectionChanged: @escaping (UUID, Bool) -> Void,
        onQuoteExcerpt: @escaping (String) -> Void,
        onSaveNoteExcerpt: @escaping (String) -> Void,
        onSpeakExcerpt: @escaping (String) -> Void
    ) {
        currentEntry = entry
        let name = temper.blockName ?? "心绪"
        symbolLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        symbolLabel.text = temper.symbol
        titleLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        titleLabel.text = name

        textView.onSelectionActiveChanged = onSelectionChanged
        textView.onQuoteSelection = onQuoteExcerpt
        textView.onSaveNoteSelection = onSaveNoteExcerpt
        textView.onSpeakSelection = onSpeakExcerpt
        textView.apply(ownerID: "live-pulse", rendered: entry.rendered, style: style)
        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        let accent = UIColor(Ink.accent).withAlphaComponent(0.85)
        symbolLabel.textColor = accent
        titleLabel.textColor = accent
        cardView.layer.cornerRadius = Ink.Radius.small
        cardView.backgroundColor = UIColor(Ink.accentWash)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let entry = currentEntry else { return }
        let margin = Ink.Space.page
        let contentW = max(120, contentView.bounds.width - margin * 2)
        let headerH = ChatCellMetrics.disclosureHeaderHeight
        symbolLabel.frame = CGRect(x: margin, y: 0, width: 16, height: headerH)
        titleLabel.frame = CGRect(x: margin + 16 + Ink.Space.s, y: 0, width: max(40, contentW - 16 - Ink.Space.s), height: headerH)

        let cardY = headerH + ChatCellMetrics.disclosureGap
        let cardH = entry.textHeight + Ink.Space.s * 2
        cardView.frame = CGRect(x: margin, y: cardY, width: contentW, height: cardH)
        textView.frame = CGRect(x: Ink.Space.m, y: Ink.Space.s, width: max(40, contentW - Ink.Space.m * 2), height: entry.textHeight)
    }
}

/// Live streaming `ThinkingBox` cell (fixed 3-line rolling window with gradient fade mask).
@MainActor
final class ChatLiveThinkingCell: UICollectionViewCell {
    static let reuseID = "ChatLiveThinkingCell"

    private let brainView = UIImageView()
    private let headerLabel = UILabel()
    private let cardView = UIView()
    private let tailLabel = UILabel()
    private let fadeMask = CAGradientLayer()

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

        brainView.image = UIImage(systemName: "brain", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .medium))
        brainView.contentMode = .scaleAspectFit
        contentView.addSubview(brainView)

        headerLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(headerLabel)

        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        contentView.addSubview(cardView)

        tailLabel.numberOfLines = 3
        cardView.addSubview(tailLabel)

        fadeMask.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.cgColor,
        ]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0.5)
        cardView.layer.mask = fadeMask

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatLiveThinkingCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    static func fixedHeight() -> CGFloat {
        let font = UIFont.systemFont(ofSize: Ink.Size.small)
        let cardH = ceil(font.lineHeight * 3) + Ink.Space.s * 2
        return ceil(ChatCellMetrics.disclosureHeaderHeight + ChatCellMetrics.disclosureGap + cardH + ChatCellMetrics.rowSpacing)
    }

    func configure(text: String) {
        brainView.image = UIImage(systemName: "brain", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .medium))
        headerLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        headerLabel.text = Words.t("正在沉吟") + " · \(text.count) 字"
        tailLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        let cut = text.suffix(220)
        tailLabel.text = cut.split(separator: "\n", omittingEmptySubsequences: true).suffix(3).joined(separator: "\n")
        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        brainView.tintColor = UIColor(Ink.inkFaint)
        headerLabel.textColor = UIColor(Ink.inkFaint)
        cardView.layer.cornerRadius = Ink.Radius.small
        cardView.backgroundColor = UIColor(Ink.paperRaised)
        cardView.layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
        tailLabel.textColor = UIColor(Ink.inkSoft)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = Ink.Space.page
        let contentW = max(120, contentView.bounds.width - margin * 2)
        let headerH = ChatCellMetrics.disclosureHeaderHeight
        brainView.frame = CGRect(x: margin, y: (headerH - 15) * 0.5, width: 15, height: 15)
        headerLabel.frame = CGRect(x: margin + 15 + Ink.Space.s, y: 0, width: max(40, contentW - 15 - Ink.Space.s), height: headerH)

        let cardY = headerH + ChatCellMetrics.disclosureGap
        let font = UIFont.systemFont(ofSize: Ink.Size.small)
        let textH = ceil(font.lineHeight * 3)
        let cardH = textH + Ink.Space.s * 2
        cardView.frame = CGRect(x: margin, y: cardY, width: contentW, height: cardH)
        tailLabel.frame = CGRect(x: Ink.Space.m, y: Ink.Space.s, width: max(40, contentW - Ink.Space.m * 2), height: textH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = cardView.bounds
        CATransaction.commit()
    }
}

/// Failure card shown below the live tail when `chat.error` is not already explained in a `.note` row.
@MainActor
final class ChatLiveFailureCell: UICollectionViewCell {
    static let reuseID = "ChatLiveFailureCell"

    var onRetry: (() -> Void)?

    private let cardView = UIView()
    private let iconView = UIImageView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var showsRetry = true

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

        cardView.layer.cornerCurve = .continuous
        contentView.addSubview(cardView)

        iconView.image = UIImage(systemName: "exclamationmark.triangle", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.sub, weight: .semibold))
        iconView.contentMode = .scaleAspectFit
        cardView.addSubview(iconView)

        errorLabel.numberOfLines = 0
        cardView.addSubview(errorLabel)

        applyRetryConfiguration()
        retryButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.onRetry?()
        }, for: .touchUpInside)
        cardView.addSubview(retryButton)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatLiveFailureCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    func configure(error: String, working: Bool, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        self.showsRetry = !working
        iconView.image = UIImage(systemName: "exclamationmark.triangle", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.sub, weight: .semibold))
        errorLabel.font = UIFont.systemFont(ofSize: Ink.Size.sub)
        errorLabel.text = error
        retryButton.isHidden = working
        applyRetryConfiguration()
        refreshColors()
        setNeedsLayout()
    }

    private func applyRetryConfiguration() {
        var cfg = retryButton.configuration ?? UIButton.Configuration.filled()
        cfg.title = L.t("actions.retry")
        cfg.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .semibold))
        cfg.imagePadding = Ink.Space.xs
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Ink.Space.m, bottom: 6, trailing: Ink.Space.m)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .semibold)
            return copy
        }
        retryButton.configuration = cfg
    }

    private func refreshColors() {
        cardView.layer.cornerRadius = Ink.Radius.small
        cardView.backgroundColor = UIColor(Ink.stopWash)
        iconView.tintColor = UIColor(Ink.stop)
        errorLabel.textColor = UIColor(Ink.stop)

        var cfg = retryButton.configuration
        cfg?.baseForegroundColor = UIColor(Ink.ink)
        cfg?.baseBackgroundColor = UIColor(Ink.paper)
        retryButton.configuration = cfg
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = Ink.Space.page
        let contentW = max(120, contentView.bounds.width - margin * 2)
        let cardH = max(44, contentView.bounds.height - ChatCellMetrics.rowSpacing)
        cardView.frame = CGRect(x: margin, y: 0, width: contentW, height: cardH)

        let padH = Ink.Space.l
        let padV = Ink.Space.m
        let iconSide: CGFloat = 20
        iconView.frame = CGRect(x: padH, y: (cardH - iconSide) * 0.5, width: iconSide, height: iconSide)

        var trailingLimit = contentW - padH
        if showsRetry {
            let btnSize = retryButton.sizeThatFits(CGSize(width: 140, height: 32))
            let btnW = max(72, ceil(btnSize.width))
            retryButton.frame = CGRect(x: contentW - padH - btnW, y: (cardH - 32) * 0.5, width: btnW, height: 32)
            trailingLimit = retryButton.frame.minX - Ink.Space.m
        }
        let textX = iconView.frame.maxX + Ink.Space.m
        errorLabel.frame = CGRect(
            x: textX,
            y: padV,
            width: max(40, trailingLimit - textX),
            height: max(20, cardH - padV * 2)
        )
    }
}

/// Queued / interjected message bubble below the live tail with withdraw & send-now actions.
@MainActor
final class ChatQueuedCell: UICollectionViewCell {
    static let reuseID = "ChatQueuedCell"

    var onWithdraw: (() -> Void)?
    var onSendNow: (() -> Void)?

    private let bubbleView = UIView()
    private let dashedBorder = CAShapeLayer()
    private let photoLabel = UILabel()
    private let messageLabel = UILabel()

    private let statusLabel = UILabel()
    private let withdrawButton = UIButton(type: .system)
    private let sendNowButton = UIButton(type: .system)

    private var currentEntry: ChatLayoutCache.QueuedLayoutEntry?
    private var sendingBlocked = false

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

        bubbleView.layer.cornerCurve = .continuous
        dashedBorder.fillColor = UIColor.clear.cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [4, 3]
        bubbleView.layer.addSublayer(dashedBorder)

        photoLabel.textAlignment = .right
        photoLabel.isHidden = true
        bubbleView.addSubview(photoLabel)

        messageLabel.numberOfLines = 4
        messageLabel.isHidden = true
        bubbleView.addSubview(messageLabel)
        contentView.addSubview(bubbleView)

        statusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusLabel)

        applyActionButtonConfigurations()
        withdrawButton.addAction(UIAction { [weak self] _ in
            self?.onWithdraw?()
        }, for: .touchUpInside)
        contentView.addSubview(withdrawButton)

        sendNowButton.addAction(UIAction { [weak self] _ in
            self?.onSendNow?()
        }, for: .touchUpInside)
        contentView.addSubview(sendNowButton)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatQueuedCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    private func applyActionButtonConfigurations() {
        var withdrawCfg = withdrawButton.configuration ?? UIButton.Configuration.plain()
        withdrawCfg.title = "撤回"
        withdrawCfg.image = UIImage(systemName: "arrow.uturn.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small))
        withdrawCfg.imagePadding = 4
        withdrawCfg.contentInsets = .zero
        withdrawCfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small)
            return copy
        }
        withdrawButton.configuration = withdrawCfg

        var sendCfg = sendNowButton.configuration ?? UIButton.Configuration.plain()
        sendCfg.title = "立即发送"
        sendCfg.image = UIImage(systemName: "paperplane.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small))
        sendCfg.imagePadding = 4
        sendCfg.contentInsets = .zero
        sendCfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .semibold)
            return copy
        }
        sendNowButton.configuration = sendCfg
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onWithdraw = nil
        onSendNow = nil
        currentEntry = nil
    }

    func configure(
        item: TeamModel.Queued,
        entry: ChatLayoutCache.QueuedLayoutEntry,
        working: Bool,
        sendingBlocked: Bool,
        onWithdraw: @escaping () -> Void,
        onSendNow: @escaping () -> Void
    ) {
        self.currentEntry = entry
        self.sendingBlocked = sendingBlocked
        self.onWithdraw = onWithdraw
        self.onSendNow = onSendNow

        if !item.photos.isEmpty {
            photoLabel.isHidden = false
            photoLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            photoLabel.text = "\(item.photos.count) 张照片"
        } else {
            photoLabel.isHidden = true
        }

        if !item.text.isEmpty {
            messageLabel.isHidden = false
            messageLabel.font = UIFont.systemFont(ofSize: Ink.Size.body, weight: .medium)
            messageLabel.text = item.text
        } else {
            messageLabel.isHidden = true
        }

        statusLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        statusLabel.text = item.interject
            ? (working ? "插话 · 这一步做完就递给它" : "还没发出")
            : (working ? "排队中，这轮做完就发" : "还没发出")

        withdrawButton.isEnabled = !sendingBlocked
        sendNowButton.isEnabled = !sendingBlocked
        let alpha: CGFloat = sendingBlocked ? 0.45 : 1
        withdrawButton.alpha = alpha
        sendNowButton.alpha = alpha

        applyActionButtonConfigurations()
        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        bubbleView.layer.cornerRadius = Ink.Radius.card
        bubbleView.backgroundColor = UIColor(Ink.mine).withAlphaComponent(0.55)
        dashedBorder.strokeColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).cgColor
        photoLabel.textColor = UIColor(Ink.inkSoft)
        messageLabel.textColor = UIColor(Ink.ink)
        statusLabel.textColor = UIColor(Ink.inkFaint)
        withdrawButton.tintColor = UIColor(Ink.accent)
        sendNowButton.tintColor = UIColor(Ink.accent)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let entry = currentEntry else { return }
        let margin = Ink.Space.page
        let rightEdge = contentView.bounds.width - margin
        let maxBubbleW = max(120, contentView.bounds.width - margin * 2 - Ink.Space.huge)
        let padH = Ink.Space.l
        let padV = Ink.Space.m
        let innerMaxW = max(60, maxBubbleW - padH * 2)

        var textW: CGFloat = 0
        if !photoLabel.isHidden {
            let pFit = photoLabel.sizeThatFits(CGSize(width: innerMaxW, height: 20))
            textW = max(textW, ceil(pFit.width))
        }
        if !messageLabel.isHidden {
            let mFit = messageLabel.sizeThatFits(CGSize(width: innerMaxW, height: .greatestFiniteMagnitude))
            textW = max(textW, min(innerMaxW, ceil(mFit.width)))
        }

        let bubbleW = min(maxBubbleW, max(64, textW + padH * 2))
        var bubbleH = padV * 2
        if entry.hasPhotos { bubbleH += 20 }
        if !messageLabel.isHidden {
            if entry.hasPhotos { bubbleH += 4 }
            bubbleH += entry.textHeight
        }

        bubbleView.frame = CGRect(x: rightEdge - bubbleW, y: 0, width: bubbleW, height: bubbleH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashedBorder.frame = bubbleView.bounds
        dashedBorder.path = UIBezierPath(roundedRect: bubbleView.bounds, cornerRadius: Ink.Radius.card).cgPath
        CATransaction.commit()

        var innerY = padV
        let innerW = bubbleW - padH * 2
        if entry.hasPhotos {
            photoLabel.frame = CGRect(x: padH, y: innerY, width: innerW, height: 20)
            innerY += 20 + (messageLabel.isHidden ? 0 : 4)
        }
        if !messageLabel.isHidden {
            messageLabel.frame = CGRect(x: padH, y: innerY, width: innerW, height: entry.textHeight)
        }

        let rowY = bubbleH + Ink.Space.xs
        let rowH: CGFloat = 24 * UIScale.factor
        let sendSize = sendNowButton.sizeThatFits(CGSize(width: 120, height: rowH))
        let sendW = ceil(sendSize.width)
        sendNowButton.frame = CGRect(x: rightEdge - sendW, y: rowY, width: sendW, height: rowH)

        let withdrawSize = withdrawButton.sizeThatFits(CGSize(width: 100, height: rowH))
        let withdrawW = ceil(withdrawSize.width)
        withdrawButton.frame = CGRect(x: sendNowButton.frame.minX - Ink.Space.m - withdrawW, y: rowY, width: withdrawW, height: rowH)

        let statusFit = statusLabel.sizeThatFits(CGSize(width: max(40, withdrawButton.frame.minX - margin - Ink.Space.m), height: rowH))
        let statusW = min(max(40, withdrawButton.frame.minX - margin - Ink.Space.m), ceil(statusFit.width))
        statusLabel.frame = CGRect(x: withdrawButton.frame.minX - Ink.Space.m - statusW, y: rowY, width: statusW, height: rowH)
    }
}

/// Centered status row shown while context compaction runs in the background.
@MainActor
final class ChatLiveFoldingCell: UICollectionViewCell {
    static let reuseID = "ChatLiveFoldingCell"

    private let iconView = UIImageView()
    private let label = UILabel()

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

        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)

        label.text = "正在后台整理较早的聊天，不耽误你接着聊"
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)

        refreshTypography()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ChatLiveFoldingCell, _) in
            cell.refreshColors()
        }
        refreshColors()
    }

    func refreshTypography() {
        iconView.image = UIImage(systemName: "text.append", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small))
        label.font = UIFont.systemFont(ofSize: Ink.Size.small)
        setNeedsLayout()
    }

    private func refreshColors() {
        iconView.tintColor = UIColor(Ink.inkFaint)
        label.textColor = UIColor(Ink.inkFaint)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = Ink.Space.page
        let contentW = max(120, contentView.bounds.width - margin * 2)
        let h: CGFloat = 24
        let iconW: CGFloat = 15
        let fit = label.sizeThatFits(CGSize(width: contentW - iconW - 6, height: h))
        let totalW = iconW + 6 + min(contentW - iconW - 6, ceil(fit.width))
        let startX = margin + max(0, (contentW - totalW) * 0.5)
        iconView.frame = CGRect(x: startX, y: (h - iconW) * 0.5, width: iconW, height: iconW)
        label.frame = CGRect(x: iconView.frame.maxX + 6, y: 0, width: totalW - iconW - 6, height: h)
    }
}

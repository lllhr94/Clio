import AgentKit
import Prose
import SwiftMath
import SwiftUI
import UIKit

/// Native UIKit code block matching `ProseView.CodeBlock`: language/output header, copy button,
/// horizontal scrolling when overflowing, selectable code text, and >20-line fold/unfold.
@MainActor
final class ChatCodeBlockView: UIView {
    let selectionOwnerID = UUID()
    var hasActiveSelection: Bool { codeTextView.selectedRange.length > 0 }

    var onToggleFold: (() -> Void)?
    var onQuoteSelection: ((String) -> Void)?
    var onSaveNoteSelection: ((String) -> Void)?
    var onSpeakSelection: ((String) -> Void)?
    var onSelectionActiveChanged: ((UUID, Bool) -> Void)?

    private let headerView = UIView()
    private let headerHairline = UIView()
    private let terminalIcon = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let copyButton = UIButton(type: .system)

    private let scrollView = UIScrollView()
    private let codeTextView = ChatRichTextView()
    private let outputStripe = UIView()
    private let trailingFade = CAGradientLayer()

    private let foldButton = UIButton(type: .system)
    private let foldHairline = UIView()

    private var currentSlice: ChatCodeSlice?
    private var currentStyle: ChatListStyle?
    private var isUnfolded = false
    private var copiedWork: DispatchWorkItem?
    private var isCopied = false
    private var lastCopySignature = ""
    private var lastFoldSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5

        addSubview(headerView)
        headerView.addSubview(headerHairline)

        terminalIcon.image = UIImage(systemName: "terminal", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        terminalIcon.contentMode = .scaleAspectFit
        headerView.addSubview(terminalIcon)

        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        countLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(countLabel)

        copyButton.addAction(UIAction { [weak self] _ in
            self?.performCopy()
        }, for: .touchUpInside)
        headerView.addSubview(copyButton)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = true
        addSubview(scrollView)

        codeTextView.allowLongPressSelection = true
        scrollView.addSubview(codeTextView)

        addSubview(outputStripe)
        layer.addSublayer(trailingFade)

        foldButton.addSubview(foldHairline)
        foldButton.addAction(UIAction { [weak self] _ in
            Haptics.tick(0.4)
            self?.onToggleFold?()
        }, for: .touchUpInside)
        addSubview(foldButton)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatCodeBlockView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
    }

    func configure(slice: ChatCodeSlice, unfolded: Bool, style: ChatListStyle) {
        let sameCode = currentSlice?.rawText == slice.rawText
            && currentSlice?.isLive == slice.isLive
            && currentSlice?.language == slice.language
            && isUnfolded == unfolded
            && currentStyle == style
        currentSlice = slice
        currentStyle = style
        isUnfolded = unfolded

        codeTextView.onQuoteSelection = { [weak self] excerpt in
            self?.onQuoteSelection?(excerpt)
        }
        codeTextView.onSaveNoteSelection = { [weak self] excerpt in
            self?.onSaveNoteSelection?(excerpt)
        }
        codeTextView.onSpeakSelection = { [weak self] excerpt in
            self?.onSpeakSelection?(excerpt)
        }
        codeTextView.onSelectionActiveChanged = { [weak self] _, active in
            guard let self else { return }
            self.onSelectionActiveChanged?(self.selectionOwnerID, active)
        }

        if !sameCode {
            terminalIcon.isHidden = !slice.isOutput
            titleLabel.font = Ink.uiMono(Ink.Size.micro, bold: false, preference: style.code)
            titleLabel.text = slice.isOutput ? "输出" : (slice.language.isEmpty ? "代码" : slice.language.lowercased())

            countLabel.isHidden = !slice.folds
            countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: Ink.Size.micro, weight: .regular)
            countLabel.text = slice.folds ? "\(slice.lineCount) 行" : nil

            outputStripe.isHidden = !slice.isOutput

            let resolved = slice.resolved(unfolded: unfolded)
            let rendered = ChatRenderedProse(
                attributed: resolved.attributed,
                decorations: .empty,
                topInset: 0,
                bottomInset: 0,
                renderToken: resolved.token,
                hasLinks: false
            )
            codeTextView.apply(
                ownerID: selectionOwnerID.uuidString,
                rendered: rendered,
                style: style,
                isLive: slice.isLive
            )

            foldButton.isHidden = !slice.folds
            if slice.folds {
                updateFoldButtonTitle(lineCount: slice.lineCount, unfolded: unfolded)
            }
            updateCopyButtonAppearance()
        }

        refreshThemeColors()
        setNeedsLayout()
    }

    func clearSelection() {
        codeTextView.clearSelectionIfNeeded()
    }

    func resetForReuse() {
        copiedWork?.cancel()
        copiedWork = nil
        isCopied = false
        currentSlice = nil
        lastCopySignature = ""
        lastFoldSignature = ""
        codeTextView.resetForReuse()
        onToggleFold = nil
        onQuoteSelection = nil
        onSaveNoteSelection = nil
        onSpeakSelection = nil
        onSelectionActiveChanged = nil
    }

    private func performCopy() {
        guard let raw = currentSlice?.rawText else { return }
        UIPasteboard.general.string = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        Haptics.tick(0.5)
        isCopied = true
        updateCopyButtonAppearance()
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isCopied = false
            self?.updateCopyButtonAppearance()
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func updateCopyButtonAppearance() {
        let theme = Theme.shared
        let signature = "\(isCopied)|\(traitCollection.userInterfaceStyle.rawValue)|\(theme.key)|\(UIScale.factor)"
        guard signature != lastCopySignature else { return }
        lastCopySignature = signature

        var config = UIButton.Configuration.plain()
        config.title = isCopied ? "已复制" : "复制"
        config.image = UIImage(
            systemName: isCopied ? "checkmark" : "doc.on.doc",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .medium)
        )
        config.imagePadding = Ink.Space.xs
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: Ink.Space.s, bottom: 2, trailing: Ink.Space.s)
        config.baseForegroundColor = UIColor(isCopied ? Ink.ok : Ink.inkSoft)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.micro, weight: .medium)
            return copy
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copyButton.configuration = config
        CATransaction.commit()
    }

    private func updateFoldButtonTitle(lineCount: Int, unfolded: Bool) {
        let theme = Theme.shared
        let signature = "\(lineCount)|\(unfolded)|\(traitCollection.userInterfaceStyle.rawValue)|\(theme.key)|\(UIScale.factor)"
        guard signature != lastFoldSignature else { return }
        lastFoldSignature = signature

        var config = UIButton.Configuration.plain()
        config.title = unfolded ? "收起" : "展开全部 \(lineCount) 行"
        config.image = UIImage(
            systemName: unfolded ? "chevron.up" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .medium)
        )
        config.imagePadding = Ink.Space.xs
        config.baseForegroundColor = UIColor(Ink.accent)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .medium)
            return copy
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        foldButton.configuration = config
        CATransaction.commit()
    }

    private func refreshThemeColors() {
        layer.cornerRadius = Ink.Radius.small
        backgroundColor = UIColor(Ink.paperRaised)
        layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.75).cgColor

        headerView.backgroundColor = UIColor(Ink.mine).withAlphaComponent(0.42)
        headerHairline.backgroundColor = UIColor(Ink.rule).withAlphaComponent(0.75)
        terminalIcon.tintColor = UIColor(Ink.Code.output)
        titleLabel.textColor = UIColor(Ink.inkSoft)
        countLabel.textColor = UIColor(Ink.inkFaint)
        outputStripe.backgroundColor = UIColor(Ink.Code.output).withAlphaComponent(0.65)
        foldButton.backgroundColor = UIColor(Ink.mine).withAlphaComponent(0.28)
        foldHairline.backgroundColor = UIColor(Ink.rule).withAlphaComponent(0.75)

        let raisedCG = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).cgColor
        let clearCG = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
        trailingFade.colors = [clearCG, raisedCG]
        trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
        trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let slice = currentSlice, let style = currentStyle else { return }
        let width = bounds.width
        let headerH = style.codeHeaderHeight
        let foldH: CGFloat = slice.folds ? style.codeFoldButtonHeight : 0

        headerView.frame = CGRect(x: 0, y: 0, width: width, height: headerH)
        headerHairline.frame = CGRect(x: 0, y: headerH - 0.5, width: width, height: 0.5)

        var leadX = Ink.Space.l
        if !terminalIcon.isHidden {
            let iconSize: CGFloat = 13 * style.scale
            terminalIcon.frame = CGRect(x: leadX, y: (headerH - iconSize) * 0.5, width: iconSize, height: iconSize)
            leadX += iconSize + Ink.Space.xs
        }

        let copySize = copyButton.sizeThatFits(CGSize(width: 120, height: headerH))
        let copyW = max(56, copySize.width)
        let copyH = min(headerH - 4, 26 * style.scale)
        copyButton.frame = CGRect(x: width - Ink.Space.s - copyW, y: (headerH - copyH) * 0.5, width: copyW, height: copyH)

        let titleFit = titleLabel.sizeThatFits(CGSize(width: max(40, copyButton.frame.minX - leadX - Ink.Space.s), height: headerH))
        titleLabel.frame = CGRect(x: leadX, y: 0, width: ceil(titleFit.width), height: headerH)
        leadX = titleLabel.frame.maxX + Ink.Space.s

        if !countLabel.isHidden {
            let maxCountW = max(0, copyButton.frame.minX - leadX - Ink.Space.s)
            let countFit = countLabel.sizeThatFits(CGSize(width: maxCountW, height: headerH))
            countLabel.frame = CGRect(x: leadX, y: 0, width: min(maxCountW, ceil(countFit.width)), height: headerH)
        }

        let bodyY = headerH
        let bodyH = max(0, bounds.height - headerH - foldH)
        scrollView.frame = CGRect(x: 0, y: bodyY, width: width, height: bodyH)

        let textSize = slice.resolved(unfolded: isUnfolded).size
        let padH = Ink.Space.l
        let padV = Ink.Space.m
        let contentW = max(width, textSize.width + padH * 2)
        scrollView.contentSize = CGSize(width: contentW, height: bodyH)
        let overflows = contentW > width + 1
        scrollView.isScrollEnabled = overflows
        codeTextView.frame = CGRect(x: padH, y: padV, width: max(width - padH * 2, textSize.width), height: max(16, textSize.height))

        outputStripe.frame = CGRect(x: 0, y: bodyY, width: 2.5, height: bodyH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailingFade.isHidden = !overflows
        trailingFade.frame = CGRect(x: max(0, width - Ink.Space.xl), y: bodyY, width: Ink.Space.xl, height: bodyH)
        CATransaction.commit()

        if slice.folds {
            let foldY = bounds.height - foldH
            foldButton.frame = CGRect(x: 0, y: foldY, width: width, height: foldH)
            foldHairline.frame = CGRect(x: 0, y: 0, width: width, height: 0.5)
        }
    }
}

/// Lightweight pooled label supporting inline markdown styles and on-tap link activation in tables.
@MainActor
private final class ChatTableCellLabel: UILabel {
    var onOpenURL: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ attr: NSAttributedString, hasLinks: Bool) {
        attributedText = attr
        isUserInteractionEnabled = hasLinks
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let attr = attributedText,
              attr.length > 0,
              bounds.width > 0,
              bounds.height > 0 else { return }
        let point = recognizer.location(in: self)
        let storage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let numGlyphs = layoutManager.numberOfGlyphs
        guard numGlyphs > 0 else { return }
        let glyphIndex = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyphIndex < numGlyphs else { return }
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        guard glyphBounds.insetBy(dx: -4, dy: -4).contains(point) else { return }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < attr.length,
              let url = attr.attribute(.link, at: charIndex, effectiveRange: nil) as? URL else { return }
        Haptics.tick(0.4)
        onOpenURL?(url)
    }
}

/// Native UIKit markdown table matching `ProseView.TableBlock` column planning, rich cell styling, horizontal scrolling, and copy menu.
@MainActor
final class ChatTableBlockView: UIView, UIContextMenuInteractionDelegate {
    private nonisolated static let colGap: CGFloat = 20

    var onOpenURL: ((URL) -> Void)?

    private let scrollView = UIScrollView()
    private let contentHolder = UIView()
    private let trailingFade = CAGradientLayer()

    private var currentSlice: ChatTableSlice?
    private var currentStyle: ChatListStyle?
    private var rowViews: [UIView] = []
    private var ruleViews: [UIView] = []
    private var cellViews: [[ChatTableCellLabel]] = []
    private var activeRowCount = 0
    private var activeColCount = 0
    private var activeRuleCount = 0
    private var lastWidth: CGFloat = 0
    private var lastLayoutHeight: CGFloat = 0
    private var lastLayoutSliceID: UInt64 = 0
    private var lastLayoutStyleKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        addSubview(scrollView)
        scrollView.addSubview(contentHolder)
        layer.addSublayer(trailingFade)

        addInteraction(UIContextMenuInteraction(delegate: self))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatTableBlockView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
    }

    nonisolated static func spreadWidths(_ natural: [CGFloat], availableRoom: CGFloat, padH: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty, availableRoom > 0 else { return natural }
        let count = CGFloat(natural.count)
        let available = availableRoom - colGap * (count - 1) - padH * 2
        guard available > 0 else { return natural }
        let floor = min(80, available / count)
        let total = natural.reduce(0, +)
        if total <= available {
            let extra = available - total
            return natural.map { $0 + extra * $0 / max(1, total) }
        }
        let comfortable = natural.map { max(floor, min($0, available * 0.35)) }
        let snug = comfortable.reduce(0, +)
        if snug <= available {
            let wants = zip(natural, comfortable).map { max(0, $0 - $1) }
            let wanted = wants.reduce(0, +)
            let extra = available - snug
            return zip(comfortable, wants).map { $0 + (wanted > 0 ? extra * $1 / wanted : extra / count) }
        }
        return natural.map { max(floor, min($0, available * 0.7)) }
    }

    nonisolated static func measureHeight(slice: ChatTableSlice, maxWidth: CGFloat, style: ChatListStyle) -> CGFloat {
        let widths = spreadWidths(slice.naturalWidths, availableRoom: maxWidth, padH: style.metrics.spaceL)
        let cellSize = style.tableCellSize
        let padV = cellSize * 0.62
        let minRowTextH = ceil(cellSize * 1.2)

        func rowHeight(_ cells: [NSAttributedString]) -> CGFloat {
            var tallest: CGFloat = minRowTextH
            for (col, colW) in widths.enumerated() where col < cells.count {
                let cell = cells[col]
                guard cell.length > 0 else { continue }
                let fit = cell.boundingRect(
                    with: CGSize(width: colW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                tallest = max(tallest, ceil(fit.height))
            }
            return tallest + padV * 2
        }

        var total = rowHeight(slice.headerCells) + 0.75
        for (idx, row) in slice.rowCells.enumerated() {
            if idx > 0 { total += 0.5 }
            total += rowHeight(row)
        }
        return ceil(total)
    }

    func configure(slice: ChatTableSlice, style: ChatListStyle) {
        if let currentSlice, let currentStyle, currentSlice == slice && currentStyle == style {
            return
        }
        currentSlice = slice
        currentStyle = style
        lastLayoutSliceID = 0
        applyGrid(slice: slice)
        refreshThemeColors()
        setNeedsLayout()
    }

    func resetForReuse() {
        currentSlice = nil
        currentStyle = nil
        lastWidth = 0
        lastLayoutHeight = 0
        lastLayoutSliceID = 0
        lastLayoutStyleKey = ""
        onOpenURL = nil
        scrollView.contentOffset = .zero
    }

    private func applyGrid(slice: ChatTableSlice) {
        scrollView.contentOffset = .zero
        let allRows = [slice.headerCells] + slice.rowCells
        let allHasLinks = [slice.headerHasLinks] + slice.rowHasLinks
        let rowCount = allRows.count
        let colCount = max(1, slice.naturalWidths.count)
        let ruleCount = max(0, rowCount - 1)

        activeRowCount = rowCount
        activeColCount = colCount
        activeRuleCount = ruleCount

        while rowViews.count < rowCount {
            let rowBg = UIView()
            contentHolder.addSubview(rowBg)
            rowViews.append(rowBg)
            cellViews.append([])
        }
        while ruleViews.count < ruleCount {
            let rule = UIView()
            contentHolder.addSubview(rule)
            ruleViews.append(rule)
        }

        for rIdx in rowViews.indices {
            let rowBg = rowViews[rIdx]
            guard rIdx < rowCount else {
                rowBg.isHidden = true
                continue
            }
            rowBg.isHidden = false
            let isHeader = rIdx == 0
            if isHeader {
                rowBg.backgroundColor = UIColor(Ink.mine).withAlphaComponent(0.45)
            } else {
                let dataIdx = rIdx - 1
                rowBg.backgroundColor = dataIdx.isMultiple(of: 2) ? .clear : UIColor(Ink.mine).withAlphaComponent(0.18)
            }

            let rowCells = allRows[rIdx]
            let rowLinks = rIdx < allHasLinks.count ? allHasLinks[rIdx] : []
            while cellViews[rIdx].count < colCount {
                let label = ChatTableCellLabel()
                label.onOpenURL = { [weak self] url in
                    self?.onOpenURL?(url)
                }
                rowBg.addSubview(label)
                cellViews[rIdx].append(label)
            }

            for col in cellViews[rIdx].indices {
                let label = cellViews[rIdx][col]
                if col < colCount {
                    label.isHidden = false
                    let cellAttr = col < rowCells.count ? rowCells[col] : NSAttributedString()
                    let hasLinks = col < rowLinks.count ? rowLinks[col] : false
                    label.apply(cellAttr, hasLinks: hasLinks)
                } else {
                    label.isHidden = true
                }
            }
        }

        for rIdx in ruleViews.indices {
            let rule = ruleViews[rIdx]
            guard rIdx < ruleCount else {
                rule.isHidden = true
                continue
            }
            rule.isHidden = false
            rule.backgroundColor = rIdx == 0 ? UIColor(Ink.rule) : UIColor(Ink.rule).withAlphaComponent(0.7)
        }
    }

    private func refreshThemeColors() {
        layer.cornerRadius = Ink.Radius.small
        backgroundColor = UIColor(Ink.paperRaised)
        layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.75).cgColor

        let raisedCG = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).cgColor
        let clearCG = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
        trailingFade.colors = [clearCG, raisedCG]
        trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
        trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let slice = currentSlice, let style = currentStyle, bounds.width > 0 else { return }
        let width = bounds.width
        let height = bounds.height
        if lastLayoutSliceID == slice.sliceID,
           lastLayoutStyleKey == style.layoutStyleKey,
           abs(lastWidth - width) <= 0.5,
           abs(lastLayoutHeight - height) <= 0.5 {
            return
        }
        scrollView.frame = bounds

        let padH = style.metrics.spaceL
        let widths = Self.spreadWidths(slice.naturalWidths, availableRoom: width, padH: padH)
        let cellSize = style.tableCellSize
        let padV = cellSize * 0.62
        let totalContentW = widths.reduce(0, +) + Self.colGap * CGFloat(max(0, widths.count - 1)) + padH * 2
        let renderW = max(width, ceil(totalContentW))

        var y: CGFloat = 0
        for rIdx in 0..<activeRowCount {
            let rowBg = rowViews[rIdx]
            let views = cellViews[rIdx]
            var maxCellH: CGFloat = ceil(cellSize * 1.2)
            var frames: [CGRect] = []
            frames.reserveCapacity(activeColCount)
            var x = padH
            for (col, colW) in widths.enumerated() {
                if col < activeColCount && col < views.count {
                    let fit = views[col].sizeThatFits(CGSize(width: colW, height: .greatestFiniteMagnitude))
                    let h = ceil(fit.height)
                    maxCellH = max(maxCellH, h)
                    frames.append(CGRect(x: x, y: padV, width: colW, height: h))
                } else {
                    frames.append(.zero)
                }
                x += colW + Self.colGap
            }
            let rowH = maxCellH + padV * 2
            rowBg.frame = CGRect(x: 0, y: y, width: renderW, height: rowH)
            for (col, frame) in frames.enumerated() where col < activeColCount && col < views.count {
                views[col].frame = frame
            }
            y += rowH
            if rIdx < activeRuleCount {
                let ruleH: CGFloat = rIdx == 0 ? 0.75 : 0.5
                ruleViews[rIdx].frame = CGRect(x: 0, y: y, width: renderW, height: ruleH)
                y += ruleH
            }
        }

        contentHolder.frame = CGRect(x: 0, y: 0, width: renderW, height: y)
        scrollView.contentSize = CGSize(width: renderW, height: bounds.height)
        let overflows = totalContentW > width + 1
        scrollView.isScrollEnabled = overflows
        scrollView.bounces = overflows

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailingFade.isHidden = !overflows
        trailingFade.frame = CGRect(x: max(0, width - Ink.Space.xl), y: 0, width: Ink.Space.xl, height: bounds.height)
        CATransaction.commit()
        lastWidth = width
        lastLayoutHeight = height
        lastLayoutSliceID = slice.sliceID
        lastLayoutStyleKey = style.layoutStyleKey
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let table = currentSlice?.table else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyTSV = UIAction(title: L.t("actions.copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = Self.plainTSV(table)
            }
            let copyMD = UIAction(title: "复制 Markdown", image: UIImage(systemName: "tablecells")) { _ in
                UIPasteboard.general.string = Self.markdownSource(table)
            }
            return UIMenu(children: [copyTSV, copyMD])
        }
    }

    private static func stripInlineMarks(_ cell: String) -> String {
        cell.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
    }

    private static func plainTSV(_ table: Prose.Table) -> String {
        ([table.header] + table.rows)
            .map { $0.map(stripInlineMarks).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private static func markdownSource(_ table: Prose.Table) -> String {
        let cols = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard cols > 0 else { return "" }
        func formatRow(_ cells: [String]) -> String {
            let padded = (0..<cols).map { idx in
                let raw = idx < cells.count ? cells[idx] : ""
                return raw.replacingOccurrences(of: "|", with: "\\|")
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [formatRow(table.header)]
        lines.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
        for row in table.rows { lines.append(formatRow(row)) }
        return lines.joined(separator: "\n")
    }
}

/// Thread-safe formula height cache and deterministic estimator usable from background layout workers and `@MainActor`.
enum ChatFormulaHeightCache {
    private struct FormulaHeightKey: Hashable, Sendable {
        let size: Double
        let uiScale: Double
        let latex: String
    }

    private static let formulaHeights = BoundedLRUCache<FormulaHeightKey, CGFloat>(countLimit: 400)

    nonisolated static func cachedHeight(latex: String, style: ChatListStyle) -> CGFloat? {
        let key = FormulaHeightKey(size: style.size, uiScale: style.uiScale, latex: latex)
        return formulaHeights.get(key)
    }

    nonisolated static func storeHeight(_ height: CGFloat, latex: String, style: ChatListStyle) {
        let key = FormulaHeightKey(size: style.size, uiScale: style.uiScale, latex: latex)
        formulaHeights.set(ceil(height), for: key)
    }

    nonisolated static func estimateHeight(latex: String, maxWidth: CGFloat, style: ChatListStyle) -> CGFloat {
        let font = style.fonts.codePlainRegular
        let pad = style.metrics.spaceM
        let textW = max(40, maxWidth - pad * 2)
        let rect = (latex as NSString).boundingRect(
            with: CGSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(44, ceil(rect.height + pad * 2))
    }
}

/// Native UIKit math formula view backed by `SwiftMath` `MTMathUILabel` with horizontal scroll & copy menu.
@MainActor
final class ChatFormulaBlockView: UIView, UIContextMenuInteractionDelegate {
    private static let measurer: MTMathUILabel = {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = .display
        label.textAlignment = .center
        return label
    }()

    var onFormulaHeightResolved: ((CGFloat) -> Void)?

    private let scrollView = UIScrollView()
    private let mathLabel = MTMathUILabel()
    private let fallbackLabel = UILabel()
    private let trailingFade = CAGradientLayer()

    private var currentLatex = ""
    private var currentStreaming = false
    private var currentStyle: ChatListStyle?
    private var expectedHeight: CGFloat = 0
    private var lastReportedResolutionSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerCurve = .continuous

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        addSubview(scrollView)

        mathLabel.displayErrorInline = false
        mathLabel.labelMode = .display
        mathLabel.textAlignment = .center
        scrollView.addSubview(mathLabel)

        fallbackLabel.numberOfLines = 0
        addSubview(fallbackLabel)

        layer.addSublayer(trailingFade)
        addInteraction(UIContextMenuInteraction(delegate: self))

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatFormulaBlockView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
    }

    nonisolated static func measureHeightInfo(
        latex: String,
        maxWidth: CGFloat,
        style: ChatListStyle,
        streaming: Bool,
        allowMainThreadMathMeasure: Bool = false
    ) -> (height: CGFloat, isEstimated: Bool) {
        if !streaming {
            if let hit = ChatFormulaHeightCache.cachedHeight(latex: latex, style: style) {
                return (hit, false)
            }
            if allowMainThreadMathMeasure, Thread.isMainThread {
                let exact: CGFloat? = MainActor.assumeIsolated {
                    measureExactOnMainThread(latex: latex, style: style)
                }
                if let exact {
                    return (exact, false)
                }
            }
        }
        return (ChatFormulaHeightCache.estimateHeight(latex: latex, maxWidth: maxWidth, style: style), true)
    }

    nonisolated static func measureHeight(latex: String, maxWidth: CGFloat, style: ChatListStyle, streaming: Bool) -> CGFloat {
        measureHeightInfo(latex: latex, maxWidth: maxWidth, style: style, streaming: streaming).height
    }

    @MainActor
    private static func measureExactOnMainThread(latex: String, style: ChatListStyle) -> CGFloat? {
        measurer.fontSize = style.readingSize + 2
        measurer.latex = latex
        let size = measurer.intrinsicContentSize
        guard measurer.error == nil, size.height > 0 else { return nil }
        let total = ceil(size.height + style.metrics.spaceM * 2)
        ChatFormulaHeightCache.storeHeight(total, latex: latex, style: style)
        return total
    }

    func resetForReuse() {
        currentLatex = ""
        currentStreaming = false
        currentStyle = nil
        expectedHeight = 0
        lastReportedResolutionSignature = ""
        onFormulaHeightResolved = nil
    }

    func configure(
        latex: String,
        style: ChatListStyle,
        streaming: Bool,
        expectedHeight: CGFloat = 0,
        onFormulaHeightResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.onFormulaHeightResolved = onFormulaHeightResolved
        let sameContent = currentLatex == latex && currentStreaming == streaming && currentStyle == style
        let expectedChanged = abs(self.expectedHeight - expectedHeight) > 0.5
        self.expectedHeight = expectedHeight
        if sameContent && !expectedChanged {
            return
        }
        currentLatex = latex
        currentStreaming = streaming
        currentStyle = style

        if !sameContent {
            fallbackLabel.font = style.fonts.codePlainRegular
            fallbackLabel.text = latex

            if streaming {
                scrollView.isHidden = true
                fallbackLabel.isHidden = false
                trailingFade.isHidden = true
            } else {
                mathLabel.fontSize = style.readingSize + 2
                if mathLabel.latex != latex { mathLabel.latex = latex }
                let failed = mathLabel.error != nil
                scrollView.isHidden = failed
                fallbackLabel.isHidden = !failed
            }
            refreshThemeColors()
            setNeedsLayout()
        }

        if !streaming, mathLabel.error == nil {
            let size = mathLabel.intrinsicContentSize
            if size.height > 0 {
                let exact = ceil(size.height + style.metrics.spaceM * 2)
                ChatFormulaHeightCache.storeHeight(exact, latex: latex, style: style)
                if expectedHeight > 0, abs(exact - expectedHeight) > 1.0 {
                    let sig = "\(latex)|\(style.styleKey)|\(Int(expectedHeight.rounded()))|\(Int(exact.rounded()))"
                    if lastReportedResolutionSignature != sig {
                        lastReportedResolutionSignature = sig
                        onFormulaHeightResolved?(exact)
                    }
                }
            }
        }
    }

    private func refreshThemeColors() {
        layer.cornerRadius = Ink.Radius.small
        backgroundColor = UIColor(Ink.accentWash).withAlphaComponent(0.4)
        mathLabel.textColor = UIColor(Ink.ink)
        fallbackLabel.textColor = UIColor(Ink.ink)

        let bgCG = UIColor(Ink.accentWash).resolvedColor(with: traitCollection).withAlphaComponent(0.4).cgColor
        let clearCG = UIColor(Ink.accentWash).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
        trailingFade.colors = [clearCG, bgCG]
        trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
        trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        if !fallbackLabel.isHidden {
            fallbackLabel.frame = CGRect(x: Ink.Space.m, y: Ink.Space.m, width: max(20, width - Ink.Space.m * 2), height: max(20, height - Ink.Space.m * 2))
            return
        }
        scrollView.frame = bounds
        let intrinsic = mathLabel.intrinsicContentSize
        let padH = Ink.Space.m
        let padV = Ink.Space.m
        let contentW = max(width, ceil(intrinsic.width) + padH * 2)
        let overflows = ceil(intrinsic.width) + padH * 2 > width + 1
        scrollView.contentSize = CGSize(width: contentW, height: height)
        scrollView.isScrollEnabled = overflows
        scrollView.bounces = overflows
        let labelW = ceil(intrinsic.width)
        let labelH = max(20, ceil(intrinsic.height))
        let x: CGFloat = overflows ? padH : max(padH, (width - labelW) * 0.5)
        let y = max(padV, (height - labelH) * 0.5)
        mathLabel.frame = CGRect(x: x, y: y, width: labelW, height: labelH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailingFade.isHidden = !overflows
        trailingFade.frame = CGRect(x: max(0, width - Ink.Space.xl), y: 0, width: Ink.Space.xl, height: height)
        CATransaction.commit()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let latex = currentLatex
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = UIAction(title: "复制公式", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = latex
            }
            return UIMenu(children: [copyAction])
        }
    }
}

/// Top-level observable payload for reusable hosted SwiftUI block views (`FileCard`, `ProsePicture`).
@MainActor @Observable
final class ChatHostedBlockModel {
    var key: String = ""
    var content: AnyView = AnyView(EmptyView())
}

private struct ChatHostedBlockWrapper: View {
    let model: ChatHostedBlockModel
    let onHeightChanged: (String, CGFloat) -> Void

    var body: some View {
        model.content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                let activeKey = model.key
                if !activeKey.isEmpty, newHeight.isFinite, newHeight > 0 {
                    onHeightChanged(activeKey, newHeight)
                }
            }
    }
}

/// Hosts compact interactive SwiftUI blocks (`FileCard`, `ProsePicture`) inside UIKit cells while reusing a single
/// `UIHostingController` across cell pooling and reporting dynamic height changes.
@MainActor
final class ChatHostedBlockView: UIView {
    private let model = ChatHostedBlockModel()
    private var controller: UIHostingController<ChatHostedBlockWrapper>?
    private weak var attachedParent: UIViewController?
    private var currentKey = ""
    private var onHeightChanged: ((String, CGFloat) -> Void)?

    func configure<V: View>(key: String, parent: UIViewController?, onHeightChanged: @escaping (CGFloat) -> Void, @ViewBuilder content: () -> V) {
        self.onHeightChanged = { reportedKey, h in
            if reportedKey == key {
                onHeightChanged(h)
            }
        }
        if currentKey == key, let controller {
            attach(controller, to: parent)
            return
        }
        model.key = key
        model.content = AnyView(content())
        currentKey = key

        if let controller {
            attach(controller, to: parent)
        } else {
            let vc = UIHostingController(rootView: ChatHostedBlockWrapper(model: model) { [weak self] reportedKey, newHeight in
                self?.onHeightChanged?(reportedKey, newHeight)
            })
            vc.safeAreaRegions = []
            vc.view.backgroundColor = .clear
            controller = vc
            addSubview(vc.view)
            attach(vc, to: parent)
        }
        setNeedsLayout()
    }

    private func attach(_ vc: UIHostingController<ChatHostedBlockWrapper>, to parent: UIViewController?) {
        if vc.parent !== parent {
            if vc.parent != nil {
                vc.willMove(toParent: nil)
                vc.removeFromParent()
            }
            if let parent {
                parent.addChild(vc)
                vc.didMove(toParent: parent)
            }
            attachedParent = parent
        }
    }

    func resetForReuse() {
        currentKey = ""
        onHeightChanged = nil
        model.key = ""
        model.content = AnyView(EmptyView())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.view.frame = bounds
    }
}

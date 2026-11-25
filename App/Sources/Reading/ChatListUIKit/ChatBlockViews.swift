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
            view.updateCopyButtonAppearance()
            if let slice = view.currentSlice, slice.folds {
                view.updateFoldButtonTitle(lineCount: slice.lineCount, unfolded: view.isUnfolded)
            }
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

    var hasSelectableText: Bool { codeTextView.hasSelectableText }

    func clearSelection() {
        codeTextView.clearSelectionIfNeeded()
    }

    @discardableResult
    func beginTextSelection() -> Bool {
        codeTextView.activateSelectionAll()
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
        config.baseForegroundColor = UIColor(isCopied ? Ink.ok : Ink.inkSoft).resolvedColor(with: traitCollection)
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
        config.baseForegroundColor = UIColor(Ink.accent).resolvedColor(with: traitCollection)
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

/// Thread-safe layout cache for decoded image aspect ratios, picture heights, and resolved file-card block heights.
enum ChatMediaLayoutCache: Sendable {
    private struct PictureHeightKey: Hashable, Sendable {
        let source: String
        let widthKey: Int
        let scaleKey: Int
    }

    private struct FileCardsHeightKey: Hashable, Sendable {
        let widthKey: Int
        let styleKey: String
        let paths: [String]
    }

    private static let localPictureAspects = BoundedLRUCache<String, CGFloat>(countLimit: 256)
    private static let remotePictureAspects = BoundedLRUCache<String, CGFloat>(countLimit: 256)
    private static let localPictureHeights = BoundedLRUCache<PictureHeightKey, CGFloat>(countLimit: 512)
    private static let remotePictureHeights = BoundedLRUCache<PictureHeightKey, CGFloat>(countLimit: 512)
    private static let fileCardHeights = BoundedLRUCache<FileCardsHeightKey, CGFloat>(countLimit: 256)

    nonisolated(unsafe) private static let mountObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: MountedFolders.changed,
        object: nil,
        queue: nil
    ) { _ in
        clearLocalEntries()
    }

    nonisolated static func isRemoteSource(_ source: String) -> Bool {
        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    nonisolated static func normalizedSource(_ source: String) -> String {
        isRemoteSource(source) ? source : (source.removingPercentEncoding ?? source)
    }

    nonisolated static func clearLocalEntries() {
        localPictureAspects.removeAll()
        localPictureHeights.removeAll()
        fileCardHeights.removeAll()
    }

    nonisolated static func pictureHeight(source: String, maxWidth: CGFloat, scale: CGFloat) -> CGFloat? {
        _ = mountObserver
        let isRemote = isRemoteSource(source)
        let norm = normalizedSource(source)
        let widthKey = Int((maxWidth * 2).rounded())
        let scaleKey = Int((scale * 100).rounded())
        let key = PictureHeightKey(source: norm, widthKey: widthKey, scaleKey: scaleKey)
        if let exact = (isRemote ? remotePictureHeights : localPictureHeights).get(key) {
            return exact
        }
        if let aspect = (isRemote ? remotePictureAspects : localPictureAspects).get(norm), aspect > 0 {
            return ceil(min(360, max(1, maxWidth) / aspect))
        }
        return nil
    }

    nonisolated static func storePictureAspect(_ aspect: CGFloat, source: String) {
        _ = mountObserver
        guard aspect.isFinite, aspect > 0 else { return }
        let isRemote = isRemoteSource(source)
        let norm = normalizedSource(source)
        (isRemote ? remotePictureAspects : localPictureAspects).set(aspect, for: norm)
    }

    nonisolated static func storePictureHeight(_ height: CGFloat, source: String, maxWidth: CGFloat, scale: CGFloat) {
        _ = mountObserver
        guard height.isFinite, height > 0 else { return }
        let isRemote = isRemoteSource(source)
        let norm = normalizedSource(source)
        let widthKey = Int((maxWidth * 2).rounded())
        let scaleKey = Int((scale * 100).rounded())
        let key = PictureHeightKey(source: norm, widthKey: widthKey, scaleKey: scaleKey)
        (isRemote ? remotePictureHeights : localPictureHeights).set(ceil(height), for: key)
    }

    nonisolated static func clearPicture(source: String) {
        _ = mountObserver
        let isRemote = isRemoteSource(source)
        let norm = normalizedSource(source)
        if isRemote {
            remotePictureAspects.removeAll { $0 == norm }
            remotePictureHeights.removeAll { $0.source == norm }
        } else {
            localPictureAspects.removeAll { $0 == norm }
            localPictureHeights.removeAll { $0.source == norm }
        }
    }

    nonisolated static func fileCardsHeight(links: [PreparsedFileLink], maxWidth: CGFloat, style: ChatListStyle) -> CGFloat? {
        _ = mountObserver
        let widthKey = Int((maxWidth * 2).rounded())
        let key = FileCardsHeightKey(widthKey: widthKey, styleKey: style.layoutStyleKey, paths: links.map(\.path))
        return fileCardHeights.get(key)
    }

    nonisolated static func storeFileCardsHeight(_ height: CGFloat, links: [PreparsedFileLink], maxWidth: CGFloat, style: ChatListStyle) {
        _ = mountObserver
        guard height.isFinite, height > 0 else { return }
        let widthKey = Int((maxWidth * 2).rounded())
        let key = FileCardsHeightKey(widthKey: widthKey, styleKey: style.layoutStyleKey, paths: links.map(\.path))
        fileCardHeights.set(ceil(height), for: key)
    }
}

/// Pure UIKit stack of workspace file cards matching `ProseView.FileCard`, with off-main resolution,
/// interactive HTML/SVG thumbnail preview, mount-safety validation, and sheet/fullScreenCover presentation.
@MainActor
final class ChatFileCardsBlockView: UIView {
    private final class CardRowView: UIControl {
        private let thumbContainer = UIView()
        private let thumbFallbackIcon = UIImageView()
        private let thumbImageView = UIImageView()

        private let badgeView = UIView()
        private let badgeGradient = CAGradientLayer()
        private let badgeIcon = UIImageView()

        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let chevronView = UIImageView()

        private(set) var link = PreparsedFileLink(label: "", path: "")
        private(set) var resolved: WorkspaceFileRef?
        private(set) var checked = false
        private var thumbImage: UIImage?
        private var generation: UInt64 = 0
        private nonisolated(unsafe) var resolveTask: Task<Void, Never>?
        private nonisolated(unsafe) var thumbTask: Task<Void, Never>?
        private var currentStyle: ChatListStyle?

        var onStateChanged: (() -> Void)?
        var onTapCard: ((CardRowView) -> Void)?

        deinit {
            resolveTask?.cancel()
            thumbTask?.cancel()
        }

        var activeResolved: WorkspaceFileRef? {
            guard let resolved, resolved.isMountCurrent else { return nil }
            return resolved
        }

        var activeDocument: InteractiveDocument? {
            guard let activeResolved, InteractiveDocument.supports(activeResolved.url) else { return nil }
            return InteractiveDocument(url: activeResolved.url, root: activeResolved.rootURL, mount: activeResolved.mount)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override var isHighlighted: Bool {
            didSet {
                guard oldValue != isHighlighted else { return }
                let nextAlpha: CGFloat = isHighlighted ? 0.85 : 1
                let nextScale: CGFloat = isHighlighted ? 0.985 : 1
                UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.alpha = nextAlpha
                    self.transform = CGAffineTransform(scaleX: nextScale, y: nextScale)
                }
            }
        }

        private func setup() {
            clipsToBounds = true
            layer.cornerCurve = .continuous
            layer.borderWidth = 0.5

            thumbContainer.clipsToBounds = true
            thumbContainer.layer.cornerCurve = .continuous
            thumbContainer.isUserInteractionEnabled = false
            thumbContainer.isHidden = true
            addSubview(thumbContainer)

            thumbFallbackIcon.contentMode = .scaleAspectFit
            thumbContainer.addSubview(thumbFallbackIcon)

            thumbImageView.contentMode = .scaleAspectFit
            thumbImageView.isHidden = true
            thumbContainer.addSubview(thumbImageView)

            badgeView.clipsToBounds = true
            badgeView.layer.cornerCurve = .continuous
            badgeView.layer.borderWidth = 0.5
            badgeView.isUserInteractionEnabled = false
            badgeGradient.startPoint = CGPoint(x: 0.5, y: 0)
            badgeGradient.endPoint = CGPoint(x: 0.5, y: 1)
            badgeView.layer.addSublayer(badgeGradient)
            addSubview(badgeView)

            badgeIcon.contentMode = .center
            badgeView.addSubview(badgeIcon)

            titleLabel.numberOfLines = 1
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.isUserInteractionEnabled = false
            addSubview(titleLabel)

            subtitleLabel.numberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.isUserInteractionEnabled = false
            addSubview(subtitleLabel)

            chevronView.contentMode = .scaleAspectFit
            chevronView.isUserInteractionEnabled = false
            addSubview(chevronView)

            addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onTapCard?(self)
            }, for: .touchUpInside)

            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CardRowView, _) in
                view.refreshThemeColors()
            }
            refreshThemeColors()
        }

        func configure(link: PreparsedFileLink, style: ChatListStyle) {
            let sameLink = self.link == link && (checked || resolveTask != nil)
            self.currentStyle = style
            if sameLink {
                if let ref = resolved, !ref.isMountCurrent {
                    clearMountInvalidated()
                } else {
                    refreshAppearance(style: style)
                    return
                }
            }

            resolveTask?.cancel()
            resolveTask = nil
            thumbTask?.cancel()
            thumbTask = nil
            generation &+= 1
            let expectedGen = generation

            self.link = link
            self.thumbImage = nil

            let clean = link.path.removingPercentEncoding ?? link.path
            if let hit = FileCardCache.get(clean) {
                resolved = hit
                checked = true
            } else {
                resolved = nil
                checked = false
            }

            refreshAppearance(style: style)
            if let doc = activeDocument {
                startThumbnailLoad(doc: doc, generation: expectedGen)
            }
            startResolve(cleanPath: clean, generation: expectedGen)
        }

        func resetForReuse() {
            resolveTask?.cancel()
            resolveTask = nil
            thumbTask?.cancel()
            thumbTask = nil
            generation &+= 1
            link = PreparsedFileLink(label: "", path: "")
            resolved = nil
            checked = false
            thumbImage = nil
            currentStyle = nil
            onStateChanged = nil
            onTapCard = nil
            thumbImageView.image = nil
            thumbImageView.isHidden = true
            thumbContainer.isHidden = true
            alpha = 1
            transform = .identity
        }

        func clearMountInvalidated() {
            let clean = link.path.removingPercentEncoding ?? link.path
            FileCardCache.set(nil, for: clean)
            resolved = nil
            checked = true
            thumbImage = nil
            thumbTask?.cancel()
            thumbTask = nil
            refreshAppearance(style: currentStyle)
        }

        func handleMountsChanged() {
            guard !link.path.isEmpty else { return }
            let clean = link.path.removingPercentEncoding ?? link.path
            if let ref = resolved, !ref.isMountCurrent {
                FileCardCache.set(nil, for: clean)
                resolved = nil
                thumbImage = nil
                thumbTask?.cancel()
                thumbTask = nil
            }
            if resolved?.mount != nil || resolved == nil {
                generation &+= 1
                thumbTask?.cancel()
                thumbTask = nil
                checked = false
                refreshAppearance(style: currentStyle)
                startResolve(cleanPath: clean, generation: generation)
            }
        }

        private func startResolve(cleanPath: String, generation expectedGen: UInt64) {
            resolveTask?.cancel()
            let startMountRevision = MountedFolders.revision
            resolveTask = Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    WorkspaceFileRef.resolve(cleanPath)
                }.value
                guard !Task.isCancelled, let self, self.generation == expectedGen else { return }
                if let found, found.mount != nil, startMountRevision != MountedFolders.revision || !found.isMountCurrent {
                    FileCardCache.set(nil, for: cleanPath)
                    self.applyResolution(nil, checked: true, generation: expectedGen)
                    return
                }
                FileCardCache.set(found, for: cleanPath, mountRevision: startMountRevision)
                self.applyResolution(found, checked: true, generation: expectedGen)
            }
        }

        private func applyResolution(_ found: WorkspaceFileRef?, checked nextChecked: Bool, generation expectedGen: UInt64) {
            guard generation == expectedGen else { return }
            let changed = (resolved != found) || (checked != nextChecked)
            resolved = found
            checked = nextChecked

            if let doc = activeDocument {
                if thumbImage == nil && thumbTask == nil {
                    startThumbnailLoad(doc: doc, generation: expectedGen)
                }
            } else {
                thumbTask?.cancel()
                thumbTask = nil
                thumbImage = nil
            }

            if changed {
                refreshAppearance(style: currentStyle)
                onStateChanged?()
            }
        }

        private func startThumbnailLoad(doc: InteractiveDocument, generation expectedGen: UInt64) {
            thumbTask?.cancel()
            thumbTask = Task { [weak self] in
                let preview = await InteractiveThumbnails.shared.image(for: doc)
                guard !Task.isCancelled, let self, self.generation == expectedGen else { return }
                self.thumbTask = nil
                guard let active = self.activeResolved, active.isMountCurrent else {
                    self.thumbImage = nil
                    self.refreshThumbnailImage()
                    return
                }
                self.thumbImage = preview
                self.refreshThumbnailImage()
            }
        }

        func refreshAppearance(style: ChatListStyle?) {
            let active = activeResolved
            let doc = activeDocument

            titleLabel.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
            titleLabel.text = link.label.isEmpty ? (link.path as NSString).lastPathComponent : link.label

            subtitleLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            if doc != nil {
                subtitleLabel.text = L.t("interactivePreview.open")
            } else if let active {
                subtitleLabel.text = FileCard.detail(active)
            } else {
                subtitleLabel.text = checked ? "找不到这个文件了" : L.t("loading.generic")
            }

            let symbol = FileCard.symbol(for: link.path)
            let symbolCfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            badgeIcon.image = UIImage(systemName: "\(symbol).fill", withConfiguration: symbolCfg)
                ?? UIImage(systemName: symbol, withConfiguration: symbolCfg)

            chevronView.isHidden = active == nil
            chevronView.image = UIImage(
                systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .semibold)
            )

            thumbContainer.isHidden = doc == nil
            thumbFallbackIcon.image = UIImage(
                systemName: "chart.xyaxis.line",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.title)
            )
            refreshThumbnailImage()

            accessibilityLabel = "打开 \(link.label)"
            accessibilityTraits = .button

            refreshThemeColors()
            setNeedsLayout()
        }

        private func refreshThumbnailImage() {
            if activeDocument != nil, let thumbImage {
                thumbImageView.image = thumbImage
                thumbImageView.isHidden = false
                thumbFallbackIcon.isHidden = true
            } else {
                thumbImageView.image = nil
                thumbImageView.isHidden = true
                thumbFallbackIcon.isHidden = false
            }
        }

        func refreshThemeColors() {
            layer.cornerRadius = Ink.Radius.small
            backgroundColor = UIColor(Ink.paperRaised)
            layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).cgColor

            thumbContainer.layer.cornerRadius = Ink.Radius.small
            thumbContainer.backgroundColor = UIColor(Ink.paperRaised)
            thumbFallbackIcon.tintColor = UIColor(Ink.inkFaint)

            let isActive = activeResolved != nil
            badgeView.backgroundColor = UIColor(isActive ? Ink.Tile.accent : Ink.Tile.off)
            badgeView.layer.cornerRadius = Kit.iconCorner(40)
            badgeView.layer.borderColor = UIColor(Ink.Tile.glyph).resolvedColor(with: traitCollection).withAlphaComponent(0.14).cgColor
            badgeIcon.tintColor = UIColor(Ink.Tile.glyph)

            let topHighlight = UIColor(Ink.Tile.glyph).resolvedColor(with: traitCollection).withAlphaComponent(0.18).cgColor
            let clearBottom = UIColor(Ink.Tile.glyph).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeGradient.colors = [topHighlight, clearBottom]
            CATransaction.commit()

            titleLabel.textColor = UIColor(Ink.ink)
            subtitleLabel.textColor = UIColor(Ink.inkSoft)
            chevronView.tintColor = UIColor(Ink.inkFaint)
        }

        func measuredHeight(forWidth width: CGFloat, style: ChatListStyle?) -> CGFloat {
            let pad = style?.metrics.spaceM ?? Ink.Space.m
            let gap = style?.metrics.spaceS ?? Ink.Space.s
            let subFont = style?.fonts.noteAdviceTitle ?? UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
            let smallFont = style?.fonts.disclosureSmall ?? UIFont.systemFont(ofSize: Ink.Size.small)
            let rowH = max(40, ceil(subFont.lineHeight) + 2 + ceil(smallFont.lineHeight))
            var total = pad * 2 + rowH
            if activeDocument != nil {
                let innerW = max(60, width - pad * 2)
                let thumbH = ceil(innerW * 3.0 / 5.0)
                total += thumbH + gap
            }
            return ceil(total)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = bounds.width
            guard w > 0 else { return }
            let pad = currentStyle?.metrics.spaceM ?? Ink.Space.m
            let gap = currentStyle?.metrics.spaceS ?? Ink.Space.s
            let innerW = max(40, w - pad * 2)
            var y = pad

            if !thumbContainer.isHidden {
                let thumbH = ceil(innerW * 3.0 / 5.0)
                thumbContainer.frame = CGRect(x: pad, y: y, width: innerW, height: thumbH)
                thumbImageView.frame = thumbContainer.bounds
                let fallbackSide: CGFloat = 28
                thumbFallbackIcon.frame = CGRect(
                    x: (innerW - fallbackSide) * 0.5,
                    y: (thumbH - fallbackSide) * 0.5,
                    width: fallbackSide,
                    height: fallbackSide
                )
                y += thumbH + gap
            }

            let rowH = max(40, bounds.height - pad - y)
            let badgeSide: CGFloat = 40
            badgeView.frame = CGRect(x: pad, y: y + (rowH - badgeSide) * 0.5, width: badgeSide, height: badgeSide)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeGradient.frame = badgeView.bounds
            CATransaction.commit()
            badgeIcon.frame = badgeView.bounds

            var trailingEdge = w - pad
            if !chevronView.isHidden {
                let chevW: CGFloat = 10
                let chevH: CGFloat = 14
                chevronView.frame = CGRect(x: trailingEdge - chevW, y: y + (rowH - chevH) * 0.5, width: chevW, height: chevH)
                trailingEdge = chevronView.frame.minX - gap
            }

            let textX = badgeView.frame.maxX + pad
            let textW = max(20, trailingEdge - textX)
            let titleH = ceil(titleLabel.font.lineHeight)
            let subH = ceil(subtitleLabel.font.lineHeight)
            let stackH = titleH + 2 + subH
            let stackY = y + (rowH - stackH) * 0.5
            titleLabel.frame = CGRect(x: textX, y: stackY, width: textW, height: titleH)
            subtitleLabel.frame = CGRect(x: textX, y: stackY + titleH + 2, width: textW, height: subH)
        }
    }

    weak var hostViewController: UIViewController?
    weak var actions: ChatListActions?
    var onHeightChanged: ((CGFloat) -> Void)?

    private var cardViews: [CardRowView] = []
    private var currentLinks: [PreparsedFileLink] = []
    private var currentStyle: ChatListStyle?
    private var containerWidth: CGFloat = 0
    private var expectedHeight: CGFloat = 0
    private var lastReportedHeightSignature = ""
    private nonisolated(unsafe) var mountObserver: NSObjectProtocol?
    private weak var presentedViewerVC: UIViewController?
    private var presentedViewerMount: MountedFolder?
    private var presentedViewerPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let observer = mountObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setup() {
        backgroundColor = .clear
        mountObserver = NotificationCenter.default.addObserver(
            forName: MountedFolders.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMountsChanged()
            }
        }
    }

    nonisolated static func baseMeasureHeight(links: [PreparsedFileLink], maxWidth: CGFloat, style: ChatListStyle) -> CGFloat {
        guard !links.isEmpty else { return 0 }
        let pad = style.metrics.spaceM
        let cardGap = style.metrics.spaceS
        let rowH = max(40, ceil(style.fonts.noteAdviceTitle.lineHeight) + 2 + ceil(style.fonts.disclosureSmall.lineHeight))
        let singleCardH = pad * 2 + rowH
        return ceil(CGFloat(links.count) * singleCardH + CGFloat(max(0, links.count - 1)) * cardGap)
    }

    func configure(
        links: [PreparsedFileLink],
        containerWidth: CGFloat,
        style: ChatListStyle,
        expectedHeight: CGFloat,
        hostViewController: UIViewController?,
        actions: ChatListActions?,
        onHeightChanged: ((CGFloat) -> Void)?
    ) {
        self.hostViewController = hostViewController
        self.actions = actions
        self.onHeightChanged = onHeightChanged
        self.containerWidth = max(1, containerWidth)
        self.expectedHeight = expectedHeight
        self.currentStyle = style
        let sameLinks = currentLinks == links
        if !sameLinks {
            lastReportedHeightSignature = ""
        }
        currentLinks = links

        while cardViews.count < links.count {
            let card = CardRowView()
            card.onStateChanged = { [weak self] in
                self?.recomputeAndReportHeightIfNeeded()
                self?.setNeedsLayout()
            }
            card.onTapCard = { [weak self] tapped in
                self?.handleTap(card: tapped)
            }
            addSubview(card)
            cardViews.append(card)
        }

        for idx in cardViews.indices {
            let card = cardViews[idx]
            if idx < links.count {
                card.isHidden = false
                card.configure(link: links[idx], style: style)
            } else {
                card.isHidden = true
                card.resetForReuse()
            }
        }

        recomputeAndReportHeightIfNeeded()
        setNeedsLayout()
    }

    func resetForReuse() {
        currentLinks = []
        currentStyle = nil
        containerWidth = 0
        expectedHeight = 0
        lastReportedHeightSignature = ""
        hostViewController = nil
        actions = nil
        onHeightChanged = nil
        presentedViewerVC = nil
        presentedViewerMount = nil
        presentedViewerPath = nil
        for card in cardViews {
            card.isHidden = true
            card.resetForReuse()
        }
    }

    private func handleMountsChanged() {
        if !currentLinks.isEmpty {
            for idx in 0..<currentLinks.count where idx < cardViews.count {
                cardViews[idx].handleMountsChanged()
            }
            recomputeAndReportHeightIfNeeded()
            setNeedsLayout()
        }
        if let vc = presentedViewerVC {
            let mountRevoked = presentedViewerMount.map { !MountedFolders.isCurrent($0) } ?? false
            let activeMissing = presentedViewerPath.map { path in
                !cardViews.prefix(currentLinks.count).contains { $0.link.path == path && $0.activeResolved != nil }
            } ?? true
            if mountRevoked || activeMissing {
                if vc.presentingViewController != nil {
                    vc.dismiss(animated: true)
                }
                presentedViewerVC = nil
                presentedViewerMount = nil
                presentedViewerPath = nil
            }
        }
    }

    private func totalMeasuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard !currentLinks.isEmpty else { return 0 }
        let cardGap = currentStyle?.metrics.spaceS ?? Ink.Space.s
        var total: CGFloat = 0
        for idx in 0..<currentLinks.count where idx < cardViews.count {
            if idx > 0 { total += cardGap }
            total += cardViews[idx].measuredHeight(forWidth: width, style: currentStyle)
        }
        return ceil(total)
    }

    private func recomputeAndReportHeightIfNeeded() {
        guard !currentLinks.isEmpty, let style = currentStyle else { return }
        let w = bounds.width > 0 ? bounds.width : containerWidth
        guard w > 0 else { return }
        let measured = totalMeasuredHeight(forWidth: w)
        let allChecked = (0..<currentLinks.count).allSatisfy { idx in
            idx < cardViews.count && cardViews[idx].checked
        }
        if allChecked {
            ChatMediaLayoutCache.storeFileCardsHeight(measured, links: currentLinks, maxWidth: w, style: style)
        }
        guard expectedHeight > 0, abs(measured - expectedHeight) > 0.5 else { return }
        let sig = "\(currentLinks.map(\.path).joined(separator: "|"))|\(Int((w * 2).rounded()))|\(Int(measured.rounded()))"
        guard sig != lastReportedHeightSignature else { return }
        lastReportedHeightSignature = sig
        onHeightChanged?(measured)
    }

    private func handleTap(card: CardRowView) {
        guard let ref = card.activeResolved else {
            if card.resolved != nil {
                card.clearMountInvalidated()
                recomputeAndReportHeightIfNeeded()
                setNeedsLayout()
            }
            return
        }
        guard ref.isMountCurrent else {
            card.clearMountInvalidated()
            recomputeAndReportHeightIfNeeded()
            setNeedsLayout()
            return
        }
        Haptics.light()
        if InteractiveDocument.supports(ref.url) {
            let doc = InteractiveDocument(url: ref.url, root: ref.rootURL, mount: ref.mount)
            if let host = hostViewController, host.presentedViewController == nil {
                let vc = UIHostingController(rootView: InteractivePreviewPage(document: doc))
                vc.modalPresentationStyle = .fullScreen
                presentedViewerVC = vc
                presentedViewerMount = ref.mount
                presentedViewerPath = card.link.path
                host.present(vc, animated: true)
            } else {
                actions?.bridge.onOpenFile(ref.url, ref.mount)
            }
        } else if let host = hostViewController, host.presentedViewController == nil {
            let vc = UIHostingController(rootView: NavigationStack {
                StudyFile(url: ref.url, mount: ref.mount, showsDone: true)
            })
            presentedViewerVC = vc
            presentedViewerMount = ref.mount
            presentedViewerPath = card.link.path
            host.present(vc, animated: true)
        } else {
            actions?.bridge.onOpenFile(ref.url, ref.mount)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0, !currentLinks.isEmpty else { return }
        let cardGap = currentStyle?.metrics.spaceS ?? Ink.Space.s
        var y: CGFloat = 0
        for idx in 0..<currentLinks.count where idx < cardViews.count {
            if idx > 0 { y += cardGap }
            let card = cardViews[idx]
            let h = card.measuredHeight(forWidth: w, style: currentStyle)
            card.frame = CGRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        recomputeAndReportHeightIfNeeded()
    }
}

/// Pure UIKit inline picture block matching `ProseView.ProsePicture`: local downsampled cache,
/// SSRF-guarded remote download, aspect-fit rounded display, error fallback, and preview sheet presentation.
@MainActor
final class ChatProsePictureView: UIView {
    private final class OwnedTempImageFile: @unchecked Sendable {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    private final class QuickPreviewHostingController: UIHostingController<AnyView> {
        private var ownedTempFile: OwnedTempImageFile?

        init(tempFile: OwnedTempImageFile) {
            self.ownedTempFile = tempFile
            super.init(rootView: AnyView(QuickPreview(url: tempFile.url).ignoresSafeArea()))
        }

        @available(*, unavailable)
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || isMovingFromParent {
                ownedTempFile = nil
            }
        }
    }

    private enum LocalOutcome: Sendable {
        case unchanged
        case missing
        case updated(WorkspaceFileRef, UIImage)
    }

    weak var hostViewController: UIViewController?
    weak var actions: ChatListActions?
    var onHeightChanged: ((CGFloat) -> Void)?

    private let loadingBox = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorIcon = UIImageView()
    private let errorLabel = UILabel()
    private let imageView = UIImageView()

    private var currentSource = ""
    private var currentLabel = ""
    private var containerWidth: CGFloat = 0
    private var currentScale: CGFloat = 1
    private var expectedHeight: CGFloat = 0
    private var lastReportedHeightSignature = ""

    private var generation: UInt64 = 0
    private nonisolated(unsafe) var loadTask: Task<Void, Never>?
    private var activeImage: UIImage?
    private var workspaceRef: WorkspaceFileRef?
    private var isFailed = false
    private var remoteFile: OwnedTempImageFile?
    private nonisolated(unsafe) var mountObserver: NSObjectProtocol?
    private weak var presentedViewerVC: UIViewController?
    private var presentedViewerMount: MountedFolder?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        loadTask?.cancel()
        if let observer = mountObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setup() {
        backgroundColor = .clear

        loadingBox.clipsToBounds = true
        loadingBox.layer.cornerCurve = .continuous
        addSubview(loadingBox)

        spinner.hidesWhenStopped = true
        loadingBox.addSubview(spinner)

        errorIcon.image = UIImage(
            systemName: "photo.badge.exclamationmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.small)
        )
        errorIcon.contentMode = .scaleAspectFit
        errorIcon.isHidden = true
        addSubview(errorIcon)

        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        addSubview(errorLabel)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerCurve = .continuous
        imageView.isUserInteractionEnabled = true
        imageView.isHidden = true
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleImageTap)))
        addSubview(imageView)

        mountObserver = NotificationCenter.default.addObserver(
            forName: MountedFolders.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMountsChanged()
            }
        }

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatProsePictureView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
    }

    private var previewMaxPixelSize: Int {
        let scale: CGFloat
        if traitCollection.displayScale > 0 {
            scale = traitCollection.displayScale
        } else if let winScale = window?.windowScene?.screen.scale, winScale > 0 {
            scale = winScale
        } else {
            scale = max(1, currentScale)
        }
        return Int(min(1440, max(720, (420 * scale).rounded())))
    }

    private var activeWorkspaceRef: WorkspaceFileRef? {
        guard let workspaceRef, workspaceRef.isMountCurrent else { return nil }
        return workspaceRef
    }

    private var displayedImage: UIImage? {
        if let workspaceRef, !workspaceRef.isMountCurrent { return nil }
        return activeImage
    }

    private var canOpen: Bool {
        activeWorkspaceRef != nil || remoteFile != nil
    }

    func configure(
        source: String,
        label: String,
        containerWidth: CGFloat,
        scale: CGFloat,
        expectedHeight: CGFloat,
        hostViewController: UIViewController?,
        actions: ChatListActions?,
        onHeightChanged: ((CGFloat) -> Void)?
    ) {
        self.hostViewController = hostViewController
        self.actions = actions
        self.onHeightChanged = onHeightChanged
        self.containerWidth = max(1, containerWidth)
        self.currentScale = max(1, scale)
        self.expectedHeight = expectedHeight

        if currentSource == source && currentLabel == label {
            if let ref = workspaceRef, !ref.isMountCurrent {
                let decodedPath = source.removingPercentEncoding ?? source
                LocalPictureCache.set(nil, for: decodedPath)
                ChatMediaLayoutCache.clearPicture(source: source)
            } else if displayedImage != nil || isFailed || loadTask != nil {
                updateVisualState()
                reportHeightIfNeeded()
                setNeedsLayout()
                return
            }
        }

        beginLoad(source: source, label: label)
    }

    func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        clearRemoteTempFile()
        currentSource = ""
        currentLabel = ""
        containerWidth = 0
        expectedHeight = 0
        lastReportedHeightSignature = ""
        activeImage = nil
        workspaceRef = nil
        isFailed = false
        hostViewController = nil
        actions = nil
        onHeightChanged = nil
        presentedViewerVC = nil
        presentedViewerMount = nil
        spinner.stopAnimating()
        imageView.image = nil
        imageView.isHidden = true
        errorIcon.isHidden = true
        errorLabel.isHidden = true
        loadingBox.isHidden = false
    }

    private func clearRemoteTempFile() {
        remoteFile = nil
    }

    private func beginLoad(source: String, label: String) {
        loadTask?.cancel()
        loadTask = nil
        clearRemoteTempFile()
        generation &+= 1
        let expectedGen = generation

        currentSource = source
        currentLabel = label
        activeImage = nil
        workspaceRef = nil
        isFailed = false
        lastReportedHeightSignature = ""

        let remote = URL(string: source).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        if let remote {
            updateVisualState()
            setNeedsLayout()
            loadTask = Task { [weak self] in
                await self?.loadRemote(remote, source: source, generation: expectedGen)
            }
            return
        }

        let decodedPath = source.removingPercentEncoding ?? source
        if let cached = LocalPictureCache.get(decodedPath) {
            workspaceRef = cached.ref
            activeImage = cached.image
            isFailed = false
            let aspect = cached.image.size.width / max(0.01, cached.image.size.height)
            ChatMediaLayoutCache.storePictureAspect(aspect, source: source)
            updateVisualState()
            reportHeightIfNeeded()
        } else {
            updateVisualState()
        }
        setNeedsLayout()

        let maxPixels = previewMaxPixelSize
        loadTask = Task { [weak self] in
            await self?.loadLocal(decodedPath: decodedPath, source: source, maxPixels: maxPixels, generation: expectedGen)
        }
    }

    private func loadRemote(_ remote: URL, source: String, generation expectedGen: UInt64) async {
        guard !LocalAddress.isLocal(remote), !(await LocalAddress.resolvesToLocal(remote)) else {
            guard !Task.isCancelled, generation == expectedGen else { return }
            isFailed = true
            ChatMediaLayoutCache.clearPicture(source: source)
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
            return
        }
        do {
            let downloaded = try await ProsePicture.downloadRemoteImage(remote)
            let preview = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let thumb = Workspace.picture(downloaded) else { return nil }
                return UIImage(data: thumb.data)
            }.value
            guard !Task.isCancelled, generation == expectedGen else {
                try? FileManager.default.removeItem(at: downloaded)
                return
            }
            guard let preview else {
                try? FileManager.default.removeItem(at: downloaded)
                isFailed = true
                ChatMediaLayoutCache.clearPicture(source: source)
                updateVisualState()
                reportHeightIfNeeded()
                setNeedsLayout()
                return
            }
            clearRemoteTempFile()
            remoteFile = OwnedTempImageFile(url: downloaded)
            activeImage = preview
            isFailed = false
            let aspect = preview.size.width / max(0.01, preview.size.height)
            ChatMediaLayoutCache.storePictureAspect(aspect, source: source)
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
        } catch {
            guard !Task.isCancelled, generation == expectedGen else { return }
            isFailed = true
            ChatMediaLayoutCache.clearPicture(source: source)
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
        }
    }

    private func loadLocal(decodedPath: String, source: String, maxPixels: Int, generation expectedGen: UInt64) async {
        let startMountRevision = MountedFolders.revision
        let cachedRef = LocalPictureCache.get(decodedPath)?.ref
        let outcome = await Task.detached(priority: .userInitiated) { () -> LocalOutcome in
            guard let ref = WorkspaceFileRef.resolve(decodedPath) else { return .missing }
            if let cachedRef, cachedRef == ref {
                return .unchanged
            }
            guard let picture = WorkspaceFileRef.loadImage(ref, maxPixelSize: maxPixels) else { return .missing }
            return .updated(ref, picture)
        }.value
        guard !Task.isCancelled, generation == expectedGen else { return }
        switch outcome {
        case .unchanged:
            if let ref = workspaceRef, !ref.isMountCurrent {
                LocalPictureCache.set(nil, for: decodedPath)
                ChatMediaLayoutCache.clearPicture(source: source)
                activeImage = nil
                workspaceRef = nil
                isFailed = true
                updateVisualState()
                reportHeightIfNeeded()
                setNeedsLayout()
            }
        case .missing:
            LocalPictureCache.set(nil, for: decodedPath)
            ChatMediaLayoutCache.clearPicture(source: source)
            activeImage = nil
            workspaceRef = nil
            isFailed = true
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
        case .updated(let ref, let picture):
            if ref.mount != nil, startMountRevision != MountedFolders.revision || !ref.isMountCurrent {
                LocalPictureCache.set(nil, for: decodedPath)
                ChatMediaLayoutCache.clearPicture(source: source)
                activeImage = nil
                workspaceRef = nil
                isFailed = true
                updateVisualState()
                reportHeightIfNeeded()
                setNeedsLayout()
                return
            }
            LocalPictureCache.set(
                CachedLocalPicture(ref: ref, image: picture, mountRevision: startMountRevision),
                for: decodedPath
            )
            workspaceRef = ref
            activeImage = picture
            isFailed = false
            let aspect = picture.size.width / max(0.01, picture.size.height)
            ChatMediaLayoutCache.storePictureAspect(aspect, source: source)
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
        }
    }

    private func handleMountsChanged() {
        if !currentSource.isEmpty {
            if let ref = workspaceRef, !ref.isMountCurrent {
                let decodedPath = currentSource.removingPercentEncoding ?? currentSource
                LocalPictureCache.set(nil, for: decodedPath)
                ChatMediaLayoutCache.clearPicture(source: currentSource)
                activeImage = nil
                workspaceRef = nil
            }
            if workspaceRef?.mount != nil || (remoteFile == nil && (activeImage == nil || isFailed)) {
                beginLoad(source: currentSource, label: currentLabel)
            }
        }
        if let vc = presentedViewerVC {
            let mountRevoked = presentedViewerMount.map { !MountedFolders.isCurrent($0) } ?? false
            let becameInvalid = presentedViewerMount != nil && activeWorkspaceRef == nil
            if mountRevoked || becameInvalid {
                if vc.presentingViewController != nil {
                    vc.dismiss(animated: true)
                }
                presentedViewerVC = nil
                presentedViewerMount = nil
            }
        }
    }

    private func updateVisualState() {
        if let displayed = displayedImage {
            loadingBox.isHidden = true
            spinner.stopAnimating()
            errorIcon.isHidden = true
            errorLabel.isHidden = true
            imageView.isHidden = false
            imageView.image = displayed
            isAccessibilityElement = true
            accessibilityLabel = currentLabel.isEmpty ? "图片" : currentLabel
            accessibilityTraits = [.image]
        } else if isFailed {
            loadingBox.isHidden = true
            spinner.stopAnimating()
            imageView.isHidden = true
            imageView.image = nil
            errorIcon.isHidden = false
            errorLabel.isHidden = false
            let msg = currentLabel.isEmpty ? "图片打不开" : "图片打不开：\(currentLabel)"
            errorLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
            errorLabel.text = msg
            isAccessibilityElement = true
            accessibilityLabel = msg
            accessibilityTraits = [.staticText]
        } else {
            imageView.isHidden = true
            imageView.image = nil
            errorIcon.isHidden = true
            errorLabel.isHidden = true
            loadingBox.isHidden = false
            spinner.startAnimating()
            isAccessibilityElement = false
        }
        refreshThemeColors()
    }

    private func refreshThemeColors() {
        loadingBox.layer.cornerRadius = Ink.Radius.small
        loadingBox.backgroundColor = UIColor(Ink.mine)
        errorIcon.tintColor = UIColor(Ink.inkFaint)
        errorLabel.textColor = UIColor(Ink.inkFaint)
        imageView.layer.cornerRadius = Ink.Radius.small
    }

    private func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if let img = displayedImage {
            let aspect = max(0.01, img.size.width) / max(0.01, img.size.height)
            let safeW = max(1, width)
            return ceil(max(1, min(360, safeW / aspect)))
        }
        if isFailed {
            let iconSide: CGFloat = 18
            let textW = max(40, width - iconSide - Ink.Space.xs)
            let fit = errorLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude))
            return ceil(max(iconSide, fit.height))
        }
        return 160
    }

    private func reportHeightIfNeeded() {
        let w = bounds.width > 0 ? bounds.width : containerWidth
        guard w > 0 else { return }
        let targetH = measuredHeight(forWidth: w)
        if displayedImage != nil {
            ChatMediaLayoutCache.storePictureHeight(targetH, source: currentSource, maxWidth: w, scale: currentScale)
        }
        guard expectedHeight > 0, abs(targetH - expectedHeight) > 0.5 else { return }
        let sig = "\(currentSource)|\(Int((w * 2).rounded()))|\(Int(targetH.rounded()))|\(isFailed ? 1 : 0)"
        guard sig != lastReportedHeightSignature else { return }
        lastReportedHeightSignature = sig
        onHeightChanged?(targetH)
    }

    @objc private func handleImageTap() {
        if let ref = workspaceRef, !ref.isMountCurrent {
            let decodedPath = currentSource.removingPercentEncoding ?? currentSource
            LocalPictureCache.set(nil, for: decodedPath)
            ChatMediaLayoutCache.clearPicture(source: currentSource)
            activeImage = nil
            workspaceRef = nil
            isFailed = true
            updateVisualState()
            reportHeightIfNeeded()
            setNeedsLayout()
            return
        }
        guard canOpen else { return }
        Haptics.light()
        if let ref = activeWorkspaceRef {
            if let host = hostViewController, host.presentedViewController == nil {
                let vc = UIHostingController(rootView: NavigationStack {
                    StudyFile(url: ref.url, mount: ref.mount, showsDone: true)
                })
                presentedViewerVC = vc
                presentedViewerMount = ref.mount
                host.present(vc, animated: true)
            } else {
                actions?.bridge.onOpenFile(ref.url, ref.mount)
            }
        } else if let remoteFile, let host = hostViewController, host.presentedViewController == nil {
            let vc = QuickPreviewHostingController(tempFile: remoteFile)
            presentedViewerVC = vc
            presentedViewerMount = nil
            host.present(vc, animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        guard w > 0 else { return }

        if let img = displayedImage {
            let aspect = max(0.01, img.size.width) / max(0.01, img.size.height)
            let targetH = min(360, w / aspect)
            let targetW = min(w, targetH * aspect)
            imageView.frame = CGRect(x: 0, y: 0, width: targetW, height: targetH)
            imageView.layer.cornerRadius = Ink.Radius.small
        } else if isFailed {
            let iconSide: CGFloat = 18
            let gap = Ink.Space.xs
            let textW = max(40, w - iconSide - gap)
            let fit = errorLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude))
            let rowH = max(iconSide, ceil(fit.height))
            errorIcon.frame = CGRect(x: 0, y: (rowH - iconSide) * 0.5, width: iconSide, height: iconSide)
            errorLabel.frame = CGRect(x: iconSide + gap, y: 0, width: textW, height: rowH)
        } else {
            let boxH = bounds.height > 0 ? min(bounds.height, 160) : 160
            loadingBox.frame = CGRect(x: 0, y: 0, width: w, height: boxH)
            loadingBox.layer.cornerRadius = Ink.Radius.small
            spinner.center = CGPoint(x: loadingBox.bounds.midX, y: loadingBox.bounds.midY)
        }
        reportHeightIfNeeded()
    }
}

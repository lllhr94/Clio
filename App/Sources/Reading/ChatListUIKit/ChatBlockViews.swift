import AgentKit
import Prose
import SwiftMath
import SwiftUI
import UIKit

/// Native UIKit code block matching `ProseView.CodeBlock`: language/output header, copy button,
/// horizontal scrolling when overflowing, selectable code text, and >20-line fold/unfold.
@MainActor
final class ChatCodeBlockView: UIView, UITextViewDelegate {
    let selectionOwnerID = UUID()

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
    private let codeTextView = UITextView(usingTextLayoutManager: true)
    private let outputStripe = UIView()
    private let trailingFade = CAGradientLayer()

    private let foldButton = UIButton(type: .system)
    private let foldHairline = UIView()

    private var currentSlice: ChatCodeSlice?
    private var currentStyle: ChatListStyle?
    private var isUnfolded = false
    private var copiedWork: DispatchWorkItem?
    private var isCopied = false
    private var wasSelecting = false

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

        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false
        codeTextView.backgroundColor = .clear
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainerInset = .zero
        codeTextView.linkTextAttributes = [:]
        codeTextView.dataDetectorTypes = []
        codeTextView.delegate = self
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

        if !sameCode {
            terminalIcon.isHidden = !slice.isOutput
            titleLabel.font = Ink.uiMono(Ink.Size.micro, bold: false, preference: style.code)
            titleLabel.text = slice.isOutput ? "输出" : (slice.language.isEmpty ? "代码" : slice.language.lowercased())

            countLabel.isHidden = !slice.folds
            countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: Ink.Size.micro, weight: .regular)
            countLabel.text = slice.folds ? "\(slice.lineCount) 行" : nil

            outputStripe.isHidden = !slice.isOutput

            let activeAttr = (slice.folds && !unfolded) ? slice.foldedAttributed : slice.fullAttributed
            let oldSelection = codeTextView.selectedRange
            let oldStr = (codeTextView.attributedText?.string ?? "") as NSString
            let newStr = activeAttr.string as NSString
            var restored: NSRange?
            if oldSelection.length > 0,
               oldSelection.location + oldSelection.length <= oldStr.length,
               oldSelection.location + oldSelection.length <= newStr.length,
               oldStr.substring(with: oldSelection) == newStr.substring(with: oldSelection) {
                restored = oldSelection
            }
            codeTextView.attributedText = activeAttr
            if let restored {
                codeTextView.selectedRange = restored
            } else if oldSelection.length > 0 {
                codeTextView.selectedRange = NSRange(location: 0, length: 0)
                publishSelection(false)
            }

            foldButton.isHidden = !slice.folds
            if slice.folds {
                updateFoldButtonTitle(lineCount: slice.lineCount, unfolded: unfolded)
            }
            updateCopyButtonAppearance()
        }

        refreshThemeColors()
        setNeedsLayout()
    }

    func resetForReuse() {
        copiedWork?.cancel()
        copiedWork = nil
        isCopied = false
        currentSlice = nil
        if codeTextView.selectedRange.length > 0 {
            codeTextView.selectedRange = NSRange(location: 0, length: 0)
        }
        publishSelection(false)
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
        copyButton.configuration = config
    }

    private func updateFoldButtonTitle(lineCount: Int, unfolded: Bool) {
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
        foldButton.configuration = config
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

        let textSize = (slice.folds && !isUnfolded) ? slice.foldedContentSize : slice.fullContentSize
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

    // MARK: - UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        publishSelection(textView.selectedRange.length > 0)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        publishSelection(false)
    }

    private func publishSelection(_ active: Bool) {
        guard active != wasSelecting else { return }
        wasSelecting = active
        onSelectionActiveChanged?(selectionOwnerID, active)
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0,
              let nsText = textView.text as NSString?,
              range.location >= 0,
              range.location + range.length <= nsText.length else {
            return UIMenu(children: suggestedActions)
        }
        let picked = ChatRichTextView.cleanExcerpt(nsText.substring(with: range))
        guard !picked.isEmpty else { return UIMenu(children: suggestedActions) }

        var custom: [UIMenuElement] = []
        if let onQuoteSelection {
            custom.append(UIAction(title: L.t("chat.quoteFollowup"), image: UIImage(systemName: "text.quote")) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onQuoteSelection(picked) }
            })
        }
        if let onSaveNoteSelection {
            custom.append(UIAction(title: L.t("saveNote.title"), image: UIImage(systemName: "square.and.arrow.down.on.square")) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSaveNoteSelection(picked) }
            })
        }
        if let onSpeakSelection {
            custom.append(UIAction(title: "朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSpeakSelection(picked) }
            })
        }
        guard !custom.isEmpty else { return UIMenu(children: suggestedActions) }
        return UIMenu(children: custom + suggestedActions)
    }
}

/// Native UIKit markdown table matching `ProseView.TableBlock` column planning, horizontal scrolling, and copy menu.
@MainActor
final class ChatTableBlockView: UIView, UIContextMenuInteractionDelegate {
    private static let colGap: CGFloat = 20

    private let scrollView = UIScrollView()
    private let contentHolder = UIView()
    private let trailingFade = CAGradientLayer()

    private var currentSlice: ChatTableSlice?
    private var currentStyle: ChatListStyle?
    private var rowViews: [UIView] = []
    private var ruleViews: [UIView] = []
    private var cellLabels: [[UILabel]] = []
    private var lastWidth: CGFloat = 0

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

    static func spreadWidths(_ natural: [CGFloat], availableRoom: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty, availableRoom > 0 else { return natural }
        let count = CGFloat(natural.count)
        let available = availableRoom - colGap * (count - 1) - Ink.Space.l * 2
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

    static func measureHeight(slice: ChatTableSlice, maxWidth: CGFloat, style: ChatListStyle) -> CGFloat {
        let widths = spreadWidths(slice.naturalWidths, availableRoom: maxWidth)
        let cellSize = style.tableCellSize
        let padV = cellSize * 0.62
        let headFont = Ink.uiFace(cellSize, bold: true, face: style.face)
        let bodyFont = Ink.uiFace(cellSize, bold: false, face: style.face)
        let lineSpacing = cellSize * 0.25

        func rowHeight(_ cells: [AttributedString], font: UIFont) -> CGFloat {
            var tallest: CGFloat = ceil(font.lineHeight)
            for (col, colW) in widths.enumerated() where col < cells.count {
                let text = String(cells[col].characters)
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = lineSpacing
                let rect = (text as NSString).boundingRect(
                    with: CGSize(width: colW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font, .paragraphStyle: pStyle],
                    context: nil
                )
                tallest = max(tallest, ceil(rect.height))
            }
            return tallest + padV * 2
        }

        var total = rowHeight(slice.prepared.header, font: headFont) + 0.75
        for (idx, row) in slice.prepared.rows.enumerated() {
            if idx > 0 { total += 0.5 }
            total += rowHeight(row, font: bodyFont)
        }
        return ceil(total)
    }

    func configure(slice: ChatTableSlice, style: ChatListStyle) {
        currentSlice = slice
        currentStyle = style
        rebuildGrid(slice: slice, style: style)
        refreshThemeColors()
        setNeedsLayout()
    }

    func resetForReuse() {
        currentSlice = nil
        lastWidth = 0
    }

    private func rebuildGrid(slice: ChatTableSlice, style: ChatListStyle) {
        rowViews.forEach { $0.removeFromSuperview() }
        ruleViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll(keepingCapacity: true)
        ruleViews.removeAll(keepingCapacity: true)
        cellLabels.removeAll(keepingCapacity: true)

        let cellSize = style.tableCellSize
        let headFont = Ink.uiFace(cellSize, bold: true, face: style.face)
        let bodyFont = Ink.uiFace(cellSize, bold: false, face: style.face)
        let allRows = [slice.prepared.header] + slice.prepared.rows
        let colCount = max(1, slice.naturalWidths.count)

        for (rIdx, row) in allRows.enumerated() {
            let isHeader = rIdx == 0
            let rowBg = UIView()
            if isHeader {
                rowBg.backgroundColor = UIColor(Ink.mine).withAlphaComponent(0.45)
            } else {
                let dataIdx = rIdx - 1
                rowBg.backgroundColor = dataIdx.isMultiple(of: 2) ? .clear : UIColor(Ink.mine).withAlphaComponent(0.18)
            }
            contentHolder.addSubview(rowBg)
            rowViews.append(rowBg)

            var labels: [UILabel] = []
            for col in 0..<colCount {
                let label = UILabel()
                label.numberOfLines = 0
                let align = col < slice.table.aligns.count ? slice.table.aligns[col] : .leading
                switch align {
                case .center: label.textAlignment = .center
                case .trailing: label.textAlignment = .right
                default: label.textAlignment = .left
                }
                let text = col < row.count ? String(row[col].characters) : ""
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = cellSize * 0.25
                pStyle.alignment = label.textAlignment
                label.attributedText = NSAttributedString(string: text, attributes: [
                    .font: isHeader ? headFont : bodyFont,
                    .foregroundColor: UIColor(Ink.ink),
                    .paragraphStyle: pStyle,
                ])
                rowBg.addSubview(label)
                labels.append(label)
            }
            cellLabels.append(labels)

            if rIdx < allRows.count - 1 {
                let rule = UIView()
                rule.backgroundColor = isHeader ? UIColor(Ink.rule) : UIColor(Ink.rule).withAlphaComponent(0.7)
                contentHolder.addSubview(rule)
                ruleViews.append(rule)
            }
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
        scrollView.frame = bounds

        let widths = Self.spreadWidths(slice.naturalWidths, availableRoom: width)
        let cellSize = style.tableCellSize
        let padV = cellSize * 0.62
        let padH = Ink.Space.l
        let totalContentW = widths.reduce(0, +) + Self.colGap * CGFloat(max(0, widths.count - 1)) + padH * 2
        let renderW = max(width, ceil(totalContentW))

        var y: CGFloat = 0
        for (rIdx, rowBg) in rowViews.enumerated() {
            let labels = cellLabels[rIdx]
            var maxCellH: CGFloat = ceil(cellSize * 1.2)
            var frames: [CGRect] = []
            var x = padH
            for (col, colW) in widths.enumerated() {
                if col < labels.count {
                    let fit = labels[col].sizeThatFits(CGSize(width: colW, height: .greatestFiniteMagnitude))
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
            for (col, frame) in frames.enumerated() where col < labels.count {
                labels[col].frame = frame
            }
            y += rowH
            if rIdx < ruleViews.count {
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

    private let scrollView = UIScrollView()
    private let mathLabel = MTMathUILabel()
    private let fallbackLabel = UILabel()
    private let trailingFade = CAGradientLayer()

    private var currentLatex = ""
    private var currentStreaming = false
    private var currentStyle: ChatListStyle?

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

    static func measureHeight(latex: String, maxWidth: CGFloat, style: ChatListStyle, streaming: Bool) -> CGFloat {
        if !streaming {
            let key = "\(style.size)|\(latex)"
            if let hit = FormulaBlock.heights[key] {
                return hit
            }
            measurer.fontSize = style.readingSize + 2
            measurer.latex = latex
            let size = measurer.intrinsicContentSize
            if measurer.error == nil, size.height > 0 {
                let total = ceil(size.height + Ink.Space.m * 2)
                if FormulaBlock.heights.count > 400 { FormulaBlock.heights.removeAll() }
                FormulaBlock.heights[key] = total
                return total
            }
        }
        let font = Ink.uiMono(style.codeSize, preference: style.code)
        let textW = max(40, maxWidth - Ink.Space.m * 2)
        let rect = (latex as NSString).boundingRect(
            with: CGSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(44, ceil(rect.height + Ink.Space.m * 2))
    }

    func configure(latex: String, style: ChatListStyle, streaming: Bool) {
        currentLatex = latex
        currentStreaming = streaming
        currentStyle = style

        fallbackLabel.font = Ink.uiMono(style.codeSize, preference: style.code)
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

/// Hosts compact interactive SwiftUI blocks (`FileCard`, `ProsePicture`) inside UIKit cells while properly attaching
/// the hosting controller so `.sheet` / `.fullScreenCover` work cleanly and dynamic height changes propagate.
@MainActor
final class ChatHostedBlockView: UIView {
    private var controller: UIHostingController<AnyView>?
    private weak var attachedParent: UIViewController?
    private var currentKey = ""

    func configure<V: View>(key: String, parent: UIViewController?, onHeightChanged: @escaping (CGFloat) -> Void, @ViewBuilder content: () -> V) {
        let wrapped = AnyView(
            content()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if newHeight.isFinite, newHeight > 0 {
                        onHeightChanged(newHeight)
                    }
                }
        )
        if let controller {
            if currentKey != key || attachedParent !== parent {
                attach(controller, to: parent)
            }
            currentKey = key
            controller.rootView = wrapped
        } else {
            let vc = UIHostingController(rootView: wrapped)
            vc.safeAreaRegions = []
            vc.view.backgroundColor = .clear
            currentKey = key
            controller = vc
            addSubview(vc.view)
            attach(vc, to: parent)
        }
        setNeedsLayout()
    }

    private func attach(_ vc: UIHostingController<AnyView>, to parent: UIViewController?) {
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
        if let vc = controller {
            if vc.parent != nil {
                vc.willMove(toParent: nil)
                vc.removeFromParent()
            }
            vc.view.removeFromSuperview()
            controller = nil
        }
        attachedParent = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.view.frame = bounds
    }
}

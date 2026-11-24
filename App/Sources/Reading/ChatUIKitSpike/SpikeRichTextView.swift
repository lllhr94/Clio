import SwiftUI
import UIKit

@MainActor
final class SpikeRichTextView: UITextView, UITextViewDelegate {
    var onQuoteSelection: ((String) -> Void)?
    var onSelectionActiveChanged: ((Bool) -> Void)?
    var onLinkTapped: ((URL) -> Void)?

    private let decorationRoot = CALayer()
    private let inlineCodeLayer = CAShapeLayer()
    private let ruleLayer = CAShapeLayer()
    private var quoteLayers: [QuoteCardLayer] = []
    private var codeLayers: [CodeCardLayer] = []

    private var decorations = SpikeBlockDecorations(
        inlineCodeRanges: [],
        codeBlocks: [],
        quoteBlocks: [],
        ruleRanges: []
    )
    private var currentStyle: SpikeStyle?
    private var lastRenderToken: UInt64 = 0
    private var lastStyleKey = ""
    private var paintedWidth: CGFloat = -1
    private var paintedToken: UInt64 = 0
    private var paintedTraitStyle: UIUserInterfaceStyle = .unspecified
    private var needsDecorationLayout = false
    private var wasSelecting = false

    private final class QuoteCardLayer: CALayer {
        let stripe = CALayer()

        override init() {
            super.init()
            cornerCurve = .continuous
            borderWidth = 0.5
            masksToBounds = true
            stripe.cornerRadius = 1.25
            addSublayer(stripe)
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) {
            nil
        }
    }

    private final class CodeCardLayer: CALayer {
        let headerBg = CALayer()
        let headerHairline = CALayer()
        let outputStripe = CALayer()
        let titleLayer = CATextLayer()

        override init() {
            super.init()
            cornerCurve = .continuous
            borderWidth = 0.5
            masksToBounds = true
            addSublayer(headerBg)
            addSublayer(headerHairline)
            addSublayer(outputStripe)
            titleLayer.alignmentMode = .left
            titleLayer.truncationMode = .end
            addSublayer(titleLayer)
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) {
            nil
        }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainerInset = .zero
        linkTextAttributes = [:]
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        delegate = self
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        decorationRoot.zPosition = -1
        decorationRoot.addSublayer(inlineCodeLayer)
        decorationRoot.addSublayer(ruleLayer)
        layer.insertSublayer(decorationRoot, at: 0)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpikeRichTextView, _) in
            view.paintedTraitStyle = .unspecified
            view.needsDecorationLayout = true
            view.setNeedsLayout()
        }
    }

    func apply(rendered: SpikeRenderedProse, style: SpikeStyle, isStreaming: Bool) {
        let sameToken = rendered.renderToken == lastRenderToken && style.styleKey == lastStyleKey
        if sameToken { return }

        let oldRange = selectedRange
        let oldString = attributedText?.string ?? ""
        let keepSelection = isStreaming
            && oldRange.length > 0
            && rendered.attributed.string.hasPrefix(oldString)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let desiredInset = UIEdgeInsets(top: rendered.topInset, left: 0, bottom: rendered.bottomInset, right: 0)
        if textContainerInset != desiredInset {
            textContainerInset = desiredInset
        }
        attributedText = rendered.attributed
        if keepSelection {
            selectedRange = oldRange
        }

        self.decorations = rendered.decorations
        self.currentStyle = style
        self.lastRenderToken = rendered.renderToken
        self.lastStyleKey = style.styleKey
        self.needsDecorationLayout = true

        CATransaction.commit()
        setNeedsLayout()
    }

    func clearSelectionIfNeeded() {
        if selectedRange.length > 0 {
            selectedRange = NSRange(location: 0, length: 0)
            publishSelection(false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDecorationsIfNeeded()
    }

    private func updateDecorationsIfNeeded() {
        guard bounds.width > 0 else { return }
        let currentInterface = traitCollection.userInterfaceStyle
        if !needsDecorationLayout
            && abs(paintedWidth - bounds.width) < 0.25
            && paintedToken == lastRenderToken
            && paintedTraitStyle == currentInterface {
            return
        }

        let hasAnyDecoration = !decorations.inlineCodeRanges.isEmpty
            || !decorations.codeBlocks.isEmpty
            || !decorations.quoteBlocks.isEmpty
            || !decorations.ruleRanges.isEmpty

        if hasAnyDecoration {
            if let tlm = textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
            } else {
                layoutManager.ensureLayout(for: textContainer)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        decorationRoot.frame = bounds
        layoutInlineCode(decorations.inlineCodeRanges)
        layoutRules(decorations.ruleRanges)
        layoutQuotes(decorations.quoteBlocks)
        layoutCodeBlocks(decorations.codeBlocks)

        CATransaction.commit()

        paintedWidth = bounds.width
        paintedToken = lastRenderToken
        paintedTraitStyle = currentInterface
        needsDecorationLayout = false
    }

    private func layoutInlineCode(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            inlineCodeLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let corner = currentStyle?.inlineCodeCorner ?? (5 * UIScale.factor)
        let length = attributedText?.length ?? 0

        for range in ranges {
            guard range.location >= 0, range.location + range.length <= length, range.length > 0,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let tr = textRange(from: start, to: end) else { continue }
            for fragment in selectionRects(for: tr) {
                guard fragment.rect.width > 0, fragment.rect.height > 0 else { continue }
                let rect = fragment.rect.insetBy(dx: -2.5, dy: fragment.rect.height * 0.06)
                let radius = min(corner, rect.height * 0.3)
                path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            }
        }
        inlineCodeLayer.path = path
        inlineCodeLayer.fillColor = UIColor(Ink.mine).resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor
    }

    private func layoutRules(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else {
            ruleLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let inset = Ink.Space.l
        let lineW = max(24, bounds.width - inset * 2)
        for range in ranges {
            guard let span = verticalSpan(for: range) else { continue }
            let midY = (span.minY + span.maxY) * 0.5
            path.addRect(CGRect(x: inset, y: midY - 0.375, width: lineW, height: 0.75))
        }
        ruleLayer.path = path
        ruleLayer.fillColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor
    }

    private func layoutQuotes(_ ranges: [NSRange]) {
        while quoteLayers.count < ranges.count {
            let layer = QuoteCardLayer()
            decorationRoot.insertSublayer(layer, at: 0)
            quoteLayers.append(layer)
        }
        let padV = Ink.Space.m
        let cardBg = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).withAlphaComponent(0.75).cgColor
        let border = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
        let stripeColor = UIColor(Ink.accent).resolvedColor(with: traitCollection).withAlphaComponent(0.52).cgColor
        let radius = Ink.Radius.small

        for (idx, layer) in quoteLayers.enumerated() {
            guard idx < ranges.count, let span = verticalSpan(for: ranges[idx]) else {
                layer.isHidden = true
                continue
            }
            let topY = max(0, span.minY - padV)
            let bottomY = min(bounds.height, span.maxY + padV)
            let frame = CGRect(x: 0, y: topY, width: bounds.width, height: max(padV * 2, bottomY - topY))
            layer.isHidden = false
            layer.frame = frame
            layer.cornerRadius = radius
            layer.backgroundColor = cardBg
            layer.borderColor = border
            layer.stripe.backgroundColor = stripeColor
            layer.stripe.frame = CGRect(
                x: Ink.Space.m,
                y: padV,
                width: 2.5,
                height: max(6, frame.height - padV * 2)
            )
        }
    }

    private func layoutCodeBlocks(_ blocks: [SpikeCodeBlockDecoration]) {
        while codeLayers.count < blocks.count {
            let layer = CodeCardLayer()
            decorationRoot.insertSublayer(layer, at: 0)
            codeLayers.append(layer)
        }

        let headerH = currentStyle?.codeHeaderHeight ?? (26 * UIScale.factor)
        let padV = Ink.Space.m
        let radius = Ink.Radius.small
        let cardBg = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).cgColor
        let border = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.8).cgColor
        let headerBg = UIColor(Ink.mine).resolvedColor(with: traitCollection).withAlphaComponent(0.42).cgColor
        let hairline = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.75).cgColor
        let outputColor = UIColor(Ink.Code.output).resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
        let titleColor = UIColor(Ink.inkSoft).resolvedColor(with: traitCollection).cgColor
        let monoFont = Ink.uiMono(Ink.Size.micro, preference: currentStyle?.code)
        let scale = max(2, traitCollection.displayScale)

        for (idx, layer) in codeLayers.enumerated() {
            guard idx < blocks.count else {
                layer.isHidden = true
                continue
            }
            let block = blocks[idx]
            guard let span = verticalSpan(for: block.range) else {
                layer.isHidden = true
                continue
            }
            let topY = max(0, span.minY - padV - headerH)
            let bottomY = min(bounds.height, span.maxY + padV)
            let frame = CGRect(x: 0, y: topY, width: bounds.width, height: max(headerH + padV * 2, bottomY - topY))

            layer.isHidden = false
            layer.frame = frame
            layer.cornerRadius = radius
            layer.backgroundColor = cardBg
            layer.borderColor = border

            layer.headerBg.frame = CGRect(x: 0, y: 0, width: frame.width, height: headerH)
            layer.headerBg.backgroundColor = headerBg

            layer.headerHairline.frame = CGRect(x: 0, y: headerH - 0.5, width: frame.width, height: 0.5)
            layer.headerHairline.backgroundColor = hairline

            if block.isOutput {
                layer.outputStripe.isHidden = false
                layer.outputStripe.frame = CGRect(x: 0, y: headerH, width: 2.5, height: max(0, frame.height - headerH))
                layer.outputStripe.backgroundColor = outputColor
            } else {
                layer.outputStripe.isHidden = true
            }

            let label = block.isOutput
                ? "输出 · \(block.lineCount) 行"
                : "\(block.language.isEmpty ? "代码" : block.language.lowercased()) · \(block.lineCount) 行"
            layer.titleLayer.contentsScale = scale
            layer.titleLayer.font = monoFont as CTFont
            layer.titleLayer.fontSize = monoFont.pointSize
            layer.titleLayer.foregroundColor = titleColor
            layer.titleLayer.string = label
            let textH = monoFont.lineHeight
            layer.titleLayer.frame = CGRect(
                x: Ink.Space.l,
                y: max(0, (headerH - textH) * 0.5),
                width: max(40, frame.width - Ink.Space.l * 2),
                height: textH
            )
        }
    }

    private func verticalSpan(for range: NSRange) -> (minY: CGFloat, maxY: CGFloat)? {
        let total = attributedText?.length ?? 0
        guard range.location >= 0, range.location + range.length <= total, range.length > 0,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let tr = textRange(from: start, to: end) else {
            return nil
        }

        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for fragment in selectionRects(for: tr) where fragment.rect.height > 0 {
            minY = min(minY, fragment.rect.minY)
            maxY = max(maxY, fragment.rect.maxY)
        }

        let startCaret = caretRect(for: start)
        if !startCaret.isNull && !startCaret.isInfinite && startCaret.height > 0 {
            minY = min(minY, startCaret.minY)
            maxY = max(maxY, startCaret.maxY)
        }
        let endCaret = caretRect(for: end)
        if !endCaret.isNull && !endCaret.isInfinite && endCaret.height > 0 {
            minY = min(minY, endCaret.minY)
            maxY = max(maxY, endCaret.maxY)
        }

        guard minY <= maxY, minY.isFinite, maxY.isFinite else { return nil }
        return (minY, maxY)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        publishSelection(textView.selectedRange.length > 0)
    }

    private func publishSelection(_ active: Bool) {
        guard active != wasSelecting else { return }
        wasSelecting = active
        onSelectionActiveChanged?(active)
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0,
              let nsText = textView.text as NSString?,
              range.location >= 0,
              range.location + range.length <= nsText.length else {
            return UIMenu(children: suggestedActions)
        }

        let rawExcerpt = nsText.substring(with: range)
        let cleaned = Self.cleanExcerpt(rawExcerpt)
        guard !cleaned.isEmpty, let onQuoteSelection else {
            return UIMenu(children: suggestedActions)
        }

        let quoteAction = UIAction(
            title: "引用",
            image: UIImage(systemName: "text.quote")
        ) { [weak self, weak textView] _ in
            textView?.selectedRange = NSRange(location: 0, length: 0)
            self?.publishSelection(false)
            DispatchQueue.main.async {
                onQuoteSelection(cleaned)
            }
        }
        return UIMenu(children: [quoteAction] + suggestedActions)
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content, let onLinkTapped {
            return UIAction { _ in onLinkTapped(url) }
        }
        return defaultAction
    }

    private static func cleanExcerpt(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count > 1200 {
            return String(stripped.prefix(1200))
        }
        return stripped
    }
}

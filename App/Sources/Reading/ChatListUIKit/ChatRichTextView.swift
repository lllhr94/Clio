import SwiftUI
import UIKit

/// Production TextKit 2 `UITextView` for selectable prose, thoughts, and user bubbles with underlying `CALayer`
/// block decorations (inline code pills, quote cards, horizontal rules) and native edit-menu actions.
@MainActor
final class ChatRichTextView: UITextView, UITextViewDelegate {
    let selectionOwnerID = UUID()

    var onQuoteSelection: ((String) -> Void)?
    var onSaveNoteSelection: ((String) -> Void)?
    var onSpeakSelection: ((String) -> Void)?
    var onSelectionActiveChanged: ((UUID, Bool) -> Void)?
    var onLinkTapped: ((URL) -> Void)?

    private let decorationRoot = CALayer()
    private let inlineCodeLayer = CAShapeLayer()
    private let ruleLayer = CAShapeLayer()
    private var quoteLayers: [QuoteCardLayer] = []

    private var decorations = ChatBlockDecorations(
        inlineCodeRanges: [],
        quoteBlocks: [],
        ruleRanges: []
    )
    private var currentOwnerID: String?
    private var currentStyle: ChatListStyle?
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

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (view: ChatRichTextView, _) in
            view.paintedTraitStyle = .unspecified
            view.needsDecorationLayout = true
            view.setNeedsLayout()
        }
    }

    func currentSelectionSnapshot() -> (range: NSRange, substring: String)? {
        let range = selectedRange
        guard range.length > 0, let text = attributedText?.string as NSString?,
              range.location >= 0, range.location + range.length <= text.length else {
            return nil
        }
        return (range, text.substring(with: range))
    }

    func apply(
        ownerID: String,
        rendered: ChatRenderedProse,
        style: ChatListStyle,
        transferredSelection: (range: NSRange, substring: String)? = nil
    ) {
        let sameOwner = currentOwnerID == ownerID
        let sameToken = sameOwner && rendered.renderToken == lastRenderToken && style.styleKey == lastStyleKey
        if sameToken && transferredSelection == nil { return }

        let oldRange = selectedRange
        let oldNS = (attributedText?.string ?? "") as NSString
        let newNS = rendered.attributed.string as NSString
        var restoredRange: NSRange?

        if let transferredSelection,
           transferredSelection.range.length > 0,
           transferredSelection.range.location >= 0,
           transferredSelection.range.location + transferredSelection.range.length <= newNS.length,
           newNS.substring(with: transferredSelection.range) == transferredSelection.substring {
            restoredRange = transferredSelection.range
        } else if sameOwner,
                  oldRange.length > 0,
                  oldRange.location >= 0,
                  oldRange.location + oldRange.length <= oldNS.length,
                  oldRange.location + oldRange.length <= newNS.length {
            let oldSelected = oldNS.substring(with: oldRange)
            let newSelected = newNS.substring(with: oldRange)
            if oldSelected == newSelected {
                restoredRange = oldRange
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let desiredInset = UIEdgeInsets(top: rendered.topInset, left: 0, bottom: rendered.bottomInset, right: 0)
        if textContainerInset != desiredInset {
            textContainerInset = desiredInset
        }
        attributedText = rendered.attributed
        if let restoredRange {
            selectedRange = restoredRange
            publishSelection(true)
        } else if oldRange.length > 0 {
            selectedRange = NSRange(location: 0, length: 0)
            publishSelection(false)
        }

        currentOwnerID = ownerID
        decorations = rendered.decorations
        currentStyle = style
        lastRenderToken = rendered.renderToken
        lastStyleKey = style.styleKey
        needsDecorationLayout = true

        CATransaction.commit()
        setNeedsLayout()
    }

    func resetForReuse() {
        currentOwnerID = nil
        lastRenderToken = 0
        lastStyleKey = ""
        clearSelectionIfNeeded()
        onQuoteSelection = nil
        onSaveNoteSelection = nil
        onSpeakSelection = nil
        onSelectionActiveChanged = nil
        onLinkTapped = nil
    }

    func clearSelectionIfNeeded() {
        if selectedRange.length > 0 {
            selectedRange = NSRange(location: 0, length: 0)
        }
        publishSelection(false)
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
            let qLayer = QuoteCardLayer()
            decorationRoot.insertSublayer(qLayer, at: 0)
            quoteLayers.append(qLayer)
        }
        let padV = Ink.Space.m
        let cardBg = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).withAlphaComponent(0.75).cgColor
        let border = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
        let stripeColor = UIColor(Ink.accent).resolvedColor(with: traitCollection).withAlphaComponent(0.52).cgColor
        let radius = Ink.Radius.small

        for (idx, qLayer) in quoteLayers.enumerated() {
            guard idx < ranges.count, let span = verticalSpan(for: ranges[idx]) else {
                qLayer.isHidden = true
                continue
            }
            let topY = max(0, span.minY - padV)
            let bottomY = min(bounds.height, span.maxY + padV)
            let frame = CGRect(x: 0, y: topY, width: bounds.width, height: max(padV * 2, bottomY - topY))
            qLayer.isHidden = false
            qLayer.frame = frame
            qLayer.cornerRadius = radius
            qLayer.backgroundColor = cardBg
            qLayer.borderColor = border
            qLayer.stripe.backgroundColor = stripeColor
            qLayer.stripe.frame = CGRect(
                x: Ink.Space.m,
                y: padV,
                width: 2.5,
                height: max(6, frame.height - padV * 2)
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

    func textViewDidEndEditing(_ textView: UITextView) {
        publishSelection(false)
    }

    func publishSelection(_ active: Bool) {
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

        let cleaned = Self.cleanExcerpt(nsText.substring(with: range))
        guard !cleaned.isEmpty else {
            return UIMenu(children: suggestedActions)
        }

        var custom: [UIMenuElement] = []
        if let onQuoteSelection {
            custom.append(UIAction(
                title: L.t("chat.quoteFollowup"),
                image: UIImage(systemName: "text.quote")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onQuoteSelection(cleaned) }
            })
        }
        if let onSaveNoteSelection {
            custom.append(UIAction(
                title: L.t("saveNote.title"),
                image: UIImage(systemName: "square.and.arrow.down.on.square")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSaveNoteSelection(cleaned) }
            })
        }
        if let onSpeakSelection {
            custom.append(UIAction(
                title: "朗读",
                image: UIImage(systemName: "speaker.wave.2")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSpeakSelection(cleaned) }
            })
        }
        guard !custom.isEmpty else {
            return UIMenu(children: suggestedActions)
        }
        return UIMenu(children: custom + suggestedActions)
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content, let onLinkTapped {
            return UIAction { _ in onLinkTapped(url) }
        }
        return defaultAction
    }

    static func cleanExcerpt(_ raw: String) -> String {
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

#if DEBUG
import SwiftUI
import UIKit

@MainActor
final class SpikeAssistantCell: UICollectionViewCell {
    static let reuseID = "SpikeAssistantCell"

    private let speakerDot = UIView()
    private let speakerLabel = UILabel()
    private let richTextView = SpikeRichTextView()
    private let statusLabel = UILabel()

    private var messageID: UUID?
    private var showSpeaker = true
    private var cachedTextHeight: CGFloat = 0

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

        speakerDot.layer.cornerRadius = 2.75
        speakerDot.backgroundColor = UIColor(Ink.accent)
        contentView.addSubview(speakerDot)

        speakerLabel.font = UIFont.systemFont(ofSize: Ink.Size.micro, weight: .semibold)
        speakerLabel.textColor = UIColor(Ink.inkSoft)
        contentView.addSubview(speakerLabel)

        contentView.addSubview(richTextView)

        statusLabel.font = Ink.uiMono(Ink.Size.micro)
        statusLabel.textColor = UIColor(Ink.inkFaint)
        contentView.addSubview(statusLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageID = nil
        richTextView.resetForReuse()
        richTextView.onQuoteSelection = nil
        richTextView.onSelectionActiveChanged = nil
        richTextView.onLinkTapped = nil
    }

    func clearSelection() {
        richTextView.clearSelectionIfNeeded()
    }

    func configure(
        message: SpikeMessage,
        entry: SpikeLayoutCache.Entry,
        style: SpikeStyle,
        showSpeaker: Bool,
        onQuote: @escaping (String, String) -> Void,
        onSelectionChanged: @escaping (Bool) -> Void,
        onLinkTapped: @escaping (URL) -> Void
    ) {
        self.messageID = message.id
        self.showSpeaker = showSpeaker
        self.cachedTextHeight = entry.textHeight

        speakerDot.isHidden = !showSpeaker
        speakerLabel.isHidden = !showSpeaker
        if showSpeaker {
            speakerDot.backgroundColor = UIColor(message.isStreaming ? Ink.accent : Ink.ok)
            let stamp = message.timestampText.isEmpty ? "" : " · \(message.timestampText)"
            speakerLabel.text = "\(message.speaker)\(stamp)"
        }

        let speaker = message.speaker
        richTextView.onQuoteSelection = { excerpt in
            onQuote(excerpt, speaker)
        }
        richTextView.onSelectionActiveChanged = onSelectionChanged
        richTextView.onLinkTapped = onLinkTapped
        richTextView.apply(messageID: message.id, rendered: entry.rendered, style: style)

        updateStatus(message: message)
        setNeedsLayout()
    }

    func updateInPlace(message: SpikeMessage, entry: SpikeLayoutCache.Entry, style: SpikeStyle) {
        guard messageID == message.id else { return }
        cachedTextHeight = entry.textHeight
        if showSpeaker {
            speakerDot.backgroundColor = UIColor(message.isStreaming ? Ink.accent : Ink.ok)
        }
        richTextView.apply(messageID: message.id, rendered: entry.rendered, style: style)
        updateStatus(message: message)
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func updateStatus(message: SpikeMessage) {
        let charCount = message.text.count
        if message.isStreaming {
            statusLabel.text = L.format("careSpike.statusStreamingFormat", charCount)
            statusLabel.textColor = UIColor(Ink.accent)
        } else {
            statusLabel.text = L.format("careSpike.statusFinalizedFormat", charCount)
            statusLabel.textColor = UIColor(Ink.inkFaint)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let pageMargin = Ink.Space.page
        let contentWidth = max(120, width - pageMargin * 2)
        var y = SpikeCellMetrics.assistantTopPad

        if showSpeaker {
            let speakerH = SpikeCellMetrics.speakerHeight
            let dotSize: CGFloat = 5.5
            speakerDot.frame = CGRect(
                x: pageMargin,
                y: y + (speakerH - dotSize) * 0.5,
                width: dotSize,
                height: dotSize
            )
            speakerLabel.frame = CGRect(
                x: pageMargin + dotSize + Ink.Space.xs,
                y: y,
                width: contentWidth - dotSize - Ink.Space.xs,
                height: speakerH
            )
            y += speakerH + SpikeCellMetrics.speakerGap
        }

        let textH = max(18, cachedTextHeight)
        richTextView.frame = CGRect(x: pageMargin, y: y, width: contentWidth, height: textH)
        y += textH + SpikeCellMetrics.footerGap

        statusLabel.frame = CGRect(
            x: pageMargin,
            y: y,
            width: contentWidth,
            height: SpikeCellMetrics.footerHeight
        )
    }
}

@MainActor
final class SpikeUserCell: UICollectionViewCell {
    static let reuseID = "SpikeUserCell"

    private let bubbleView = UIView()
    private let quoteStripe = UIView()
    private let quoteLabel = UILabel()
    private let richTextView = SpikeRichTextView()

    private var cachedBubbleWidth: CGFloat = 180
    private var cachedTextWidth: CGFloat = 140
    private var cachedTextHeight: CGFloat = 24
    private var cachedQuoteHeight: CGFloat = 0

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
        bubbleView.layer.borderWidth = 0.75
        bubbleView.layer.shadowRadius = 8
        bubbleView.layer.shadowOffset = CGSize(width: 0, height: 3)
        bubbleView.layer.shadowOpacity = 1
        contentView.addSubview(bubbleView)

        quoteStripe.layer.cornerRadius = 1
        bubbleView.addSubview(quoteStripe)

        quoteLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        quoteLabel.numberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        bubbleView.addSubview(quoteLabel)

        bubbleView.addSubview(richTextView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: SpikeUserCell, _) in
            cell.refreshThemeColors()
        }
        refreshThemeColors()
    }

    private func refreshThemeColors() {
        bubbleView.backgroundColor = UIColor(Ink.bubble)
        bubbleView.layer.cornerRadius = Ink.Radius.card
        bubbleView.layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).cgColor
        bubbleView.layer.shadowColor = UIColor(Ink.bubbleShadow).resolvedColor(with: traitCollection).cgColor
        quoteStripe.backgroundColor = UIColor(Ink.accent)
        quoteLabel.textColor = UIColor(Ink.inkSoft)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        richTextView.resetForReuse()
        richTextView.onQuoteSelection = nil
        richTextView.onSelectionActiveChanged = nil
    }

    func clearSelection() {
        richTextView.clearSelectionIfNeeded()
    }

    func configure(
        message: SpikeMessage,
        entry: SpikeLayoutCache.Entry,
        style: SpikeStyle,
        onQuote: @escaping (String, String) -> Void,
        onSelectionChanged: @escaping (Bool) -> Void
    ) {
        cachedBubbleWidth = entry.bubbleWidth
        cachedTextWidth = entry.textWidth
        cachedTextHeight = entry.textHeight
        cachedQuoteHeight = entry.quoteHeight

        let hasQuote = (message.quote?.isEmpty == false) && entry.quoteHeight > 0
        quoteStripe.isHidden = !hasQuote
        quoteLabel.isHidden = !hasQuote
        quoteLabel.text = message.quote

        let speaker = message.speaker
        richTextView.onQuoteSelection = { excerpt in
            onQuote(excerpt, speaker)
        }
        richTextView.onSelectionActiveChanged = onSelectionChanged
        richTextView.apply(messageID: message.id, rendered: entry.rendered, style: style)

        refreshThemeColors()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let pageMargin = Ink.Space.page
        let padH = SpikeCellMetrics.userBubbleHorizontalPad
        let topPad = SpikeCellMetrics.userBubbleTopPad
        let bottomPad = SpikeCellMetrics.userBubbleBottomPad

        let bubbleH = topPad
            + (cachedQuoteHeight > 0 ? cachedQuoteHeight + SpikeCellMetrics.userQuoteHeightGap : 0)
            + cachedTextHeight
            + bottomPad

        let bubbleX = max(Ink.Space.huge, width - pageMargin - cachedBubbleWidth)
        bubbleView.frame = CGRect(x: bubbleX, y: 0, width: cachedBubbleWidth, height: bubbleH)

        var innerY = topPad
        if cachedQuoteHeight > 0 {
            quoteStripe.frame = CGRect(x: padH, y: innerY + 1, width: 2.5, height: max(10, cachedQuoteHeight - 2))
            quoteLabel.frame = CGRect(
                x: padH + 2.5 + Ink.Space.s,
                y: innerY,
                width: max(40, cachedTextWidth - 2.5 - Ink.Space.s),
                height: cachedQuoteHeight
            )
            innerY += cachedQuoteHeight + SpikeCellMetrics.userQuoteHeightGap
        }

        richTextView.frame = CGRect(x: padH, y: innerY, width: cachedTextWidth, height: cachedTextHeight)
    }
}
#endif

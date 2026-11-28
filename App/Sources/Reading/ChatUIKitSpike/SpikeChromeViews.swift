#if DEBUG
import SwiftUI
import UIKit

@MainActor
final class SpikeHUDView: UIView {
    var onDismiss: (() -> Void)?
    var onLoadEarlier: (() -> Void)?
    var onToggleStream: (() -> Void)?
    var onScrollTop: (() -> Void)?
    var onScrollBottom: (() -> Void)?
    var onReset: (() -> Void)?

    private let paperBackdrop = UIView()
    private let fadeLayer = CAGradientLayer()

    private let titleLabel = UILabel()
    private let fpsPill = UIView()
    private let fpsDot = UIView()
    private let fpsLabel = UILabel()
    private let countLabel = UILabel()
    private let anchorPill = UIView()
    private let anchorLabel = UILabel()
    private let doneButton = UIButton(type: .system)

    private let stripScroll = UIScrollView()
    private let stripStack = UIStackView()
    private var prependButton: UIButton!
    private var streamButton: UIButton!
    private var topButton: UIButton!
    private var bottomButton: UIButton!
    private var resetButton: UIButton!
    private let streamDeltaLabel = UILabel()

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
        clipsToBounds = false

        addSubview(paperBackdrop)
        layer.addSublayer(fadeLayer)

        titleLabel.text = L.t("careSpike.title")
        titleLabel.font = UIFont.systemFont(ofSize: Ink.Size.sub, weight: .semibold)
        titleLabel.textColor = UIColor(Ink.ink)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fpsDot.layer.cornerRadius = 3
        fpsLabel.font = Ink.uiMono(Ink.Size.micro, bold: true)
        fpsLabel.text = L.t("careSpike.fpsPlaceholder")

        countLabel.font = Ink.uiMono(Ink.Size.micro)
        countLabel.textColor = UIColor(Ink.inkSoft)
        countLabel.text = L.format("careSpike.messageCount", 24)

        fpsPill.layer.cornerCurve = .continuous
        fpsPill.layer.borderWidth = 0.5
        let fpsStack = UIStackView(arrangedSubviews: [fpsDot, fpsLabel, countLabel])
        fpsStack.axis = .horizontal
        fpsStack.alignment = .center
        fpsStack.spacing = Ink.Space.xs
        fpsStack.translatesAutoresizingMaskIntoConstraints = false
        fpsPill.addSubview(fpsStack)
        NSLayoutConstraint.activate([
            fpsDot.widthAnchor.constraint(equalToConstant: 6),
            fpsDot.heightAnchor.constraint(equalToConstant: 6),
            fpsStack.leadingAnchor.constraint(equalTo: fpsPill.leadingAnchor, constant: Ink.Space.s),
            fpsStack.trailingAnchor.constraint(equalTo: fpsPill.trailingAnchor, constant: -Ink.Space.s),
            fpsStack.topAnchor.constraint(equalTo: fpsPill.topAnchor, constant: 4),
            fpsStack.bottomAnchor.constraint(equalTo: fpsPill.bottomAnchor, constant: -4),
        ])

        anchorLabel.font = Ink.uiMono(Ink.Size.micro, bold: true)
        anchorLabel.text = L.t("careSpike.anchorIdle")
        anchorPill.layer.cornerCurve = .continuous
        anchorPill.layer.borderWidth = 0.5
        anchorLabel.translatesAutoresizingMaskIntoConstraints = false
        anchorPill.addSubview(anchorLabel)
        NSLayoutConstraint.activate([
            anchorLabel.leadingAnchor.constraint(equalTo: anchorPill.leadingAnchor, constant: Ink.Space.s),
            anchorLabel.trailingAnchor.constraint(equalTo: anchorPill.trailingAnchor, constant: -Ink.Space.s),
            anchorLabel.topAnchor.constraint(equalTo: anchorPill.topAnchor, constant: 4),
            anchorLabel.bottomAnchor.constraint(equalTo: anchorPill.bottomAnchor, constant: -4),
        ])

        var doneConfig = UIButton.Configuration.plain()
        doneConfig.title = L.t("actions.done")
        doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        doneConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .semibold)
            return copy
        }
        doneButton.configuration = doneConfig
        doneButton.layer.cornerCurve = .continuous
        doneButton.layer.borderWidth = 0.5
        doneButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.onDismiss?()
        }, for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        fpsPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        fpsPill.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, spacer, fpsPill, doneButton])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = Ink.Space.s
        topRow.translatesAutoresizingMaskIntoConstraints = false

        prependButton = makeChip(title: L.t("careSpike.loadEarlier"), symbol: "arrow.up.to.line") { [weak self] in
            Haptics.light()
            self?.onLoadEarlier?()
        }
        streamButton = makeChip(title: L.t("careSpike.simulateStream"), symbol: "sparkles") { [weak self] in
            Haptics.light()
            self?.onToggleStream?()
        }
        topButton = makeChip(title: L.t("careSpike.scrollTop"), symbol: "arrow.up") { [weak self] in
            Haptics.tick(0.5)
            self?.onScrollTop?()
        }
        bottomButton = makeChip(title: L.t("careSpike.scrollBottom"), symbol: "arrow.down.to.line") { [weak self] in
            Haptics.tick(0.5)
            self?.onScrollBottom?()
        }
        resetButton = makeChip(title: L.t("careSpike.reset"), symbol: "arrow.counterclockwise") { [weak self] in
            Haptics.light()
            self?.onReset?()
        }

        streamDeltaLabel.font = Ink.uiMono(Ink.Size.micro)
        streamDeltaLabel.textColor = UIColor(Ink.inkSoft)
        streamDeltaLabel.text = ""

        stripScroll.showsHorizontalScrollIndicator = false
        stripScroll.alwaysBounceHorizontal = true
        stripScroll.translatesAutoresizingMaskIntoConstraints = false

        stripStack.axis = .horizontal
        stripStack.alignment = .center
        stripStack.spacing = Ink.Space.xs
        stripStack.translatesAutoresizingMaskIntoConstraints = false
        [prependButton, streamButton, anchorPill, topButton, bottomButton, resetButton, streamDeltaLabel].forEach {
            stripStack.addArrangedSubview($0)
        }
        stripScroll.addSubview(stripStack)

        addSubview(topRow)
        addSubview(stripScroll)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Ink.Space.xs),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Ink.Bar.edge),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Ink.Bar.edge),

            stripScroll.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: Ink.Space.xs),
            stripScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Ink.Space.s),
            stripScroll.heightAnchor.constraint(equalToConstant: 32 * UIScale.factor),

            stripStack.leadingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.leadingAnchor, constant: Ink.Bar.edge),
            stripStack.trailingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.trailingAnchor, constant: -Ink.Bar.edge),
            stripStack.topAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.topAnchor),
            stripStack.bottomAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.bottomAnchor),
            stripStack.heightAnchor.constraint(equalTo: stripScroll.frameLayoutGuide.heightAnchor),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpikeHUDView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperBackdrop.frame = bounds
        let fadeHeight = Ink.Space.m
        fadeLayer.frame = CGRect(x: 0, y: bounds.height, width: bounds.width, height: fadeHeight)
        fpsPill.layer.cornerRadius = fpsPill.bounds.height * 0.5
        anchorPill.layer.cornerRadius = anchorPill.bounds.height * 0.5
        doneButton.layer.cornerRadius = doneButton.bounds.height * 0.5
        for view in stripStack.arrangedSubviews {
            if let btn = view as? UIButton {
                btn.layer.cornerRadius = btn.bounds.height * 0.5
            }
        }
        refreshGradientColors()
    }

    private func makeChip(title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = UIFont.systemFont(ofSize: Ink.Size.micro, weight: .medium)
            return copy
        }
        button.configuration = config
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.5
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    func updateFPS(_ fps: Int, maxFPS: Int, worstMs: Double, hitches: Int) {
        let thresholdHigh = Double(maxFPS) * 0.88
        let thresholdMid = Double(maxFPS) * 0.65
        let color: Color
        if Double(fps) >= thresholdHigh {
            color = Ink.ok
        } else if Double(fps) >= thresholdMid {
            color = Ink.accent
        } else {
            color = Ink.stop
        }
        let uiColor = UIColor(color)
        fpsDot.backgroundColor = uiColor
        fpsLabel.textColor = uiColor
        if hitches > 0 {
            fpsLabel.text = L.format("careSpike.fpsHitchFormat", fps, Int(worstMs.rounded()))
        } else {
            fpsLabel.text = L.format("careSpike.fpsFormat", fps)
        }
    }

    func updateMessageCount(_ count: Int) {
        countLabel.text = L.format("careSpike.messageCount", count)
    }

    func updateAnchorDelta(_ delta: CGFloat?, source: String) {
        guard let delta else {
            anchorLabel.text = L.t("careSpike.anchorUnverified")
            anchorLabel.textColor = UIColor(Ink.warn)
            anchorPill.backgroundColor = UIColor(Ink.stopWash).withAlphaComponent(0.7)
            prependButton.accessibilityHint = source
            return
        }
        let clamped = abs(delta) < 0.05 ? 0.0 : Double(delta)
        anchorLabel.text = L.format("careSpike.anchorDeltaFormat", clamped)
        let ok = abs(clamped) < 0.5
        anchorLabel.textColor = UIColor(ok ? Ink.ok : Ink.warn)
        anchorPill.backgroundColor = UIColor(ok ? Ink.accentWash : Ink.stopWash).withAlphaComponent(0.7)
        prependButton.accessibilityHint = source
    }

    func updateStreamState(isStreaming: Bool, finalizeDelta: CGFloat?) {
        var config = streamButton.configuration
        if isStreaming {
            config?.title = L.t("careSpike.stopStream")
            config?.image = UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
            streamButton.tintColor = UIColor(Ink.stop)
            streamButton.backgroundColor = UIColor(Ink.stopWash)
            streamDeltaLabel.text = L.t("careSpike.streamingNow")
            streamDeltaLabel.textColor = UIColor(Ink.accent)
        } else {
            config?.title = L.t("careSpike.simulateStream")
            config?.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
            streamButton.tintColor = UIColor(Ink.accent)
            streamButton.backgroundColor = UIColor(Ink.paperRaised)
            if let finalizeDelta {
                let shown = abs(finalizeDelta) < 0.05 ? 0.0 : Double(finalizeDelta)
                streamDeltaLabel.text = L.format("careSpike.finalizeDeltaFormat", shown)
                streamDeltaLabel.textColor = UIColor(abs(shown) < 0.5 ? Ink.ok : Ink.warn)
            }
        }
        streamButton.configuration = config
    }

    func resetMetrics() {
        anchorLabel.text = L.t("careSpike.anchorIdle")
        anchorLabel.textColor = UIColor(Ink.inkSoft)
        anchorPill.backgroundColor = UIColor(Ink.paperRaised)
        streamDeltaLabel.text = ""
    }

    private func refreshThemeColors() {
        paperBackdrop.backgroundColor = UIColor(Ink.paper)
        let raised = UIColor(Ink.paperRaised)
        let rule = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.8).cgColor

        fpsPill.backgroundColor = raised
        fpsPill.layer.borderColor = rule

        anchorPill.backgroundColor = raised
        anchorPill.layer.borderColor = rule
        if anchorLabel.text == L.t("careSpike.anchorIdle") {
            anchorLabel.textColor = UIColor(Ink.inkSoft)
        }

        doneButton.backgroundColor = raised
        doneButton.tintColor = UIColor(Ink.ink)
        doneButton.layer.borderColor = rule

        for button in [prependButton, streamButton, topButton, bottomButton, resetButton] {
            guard let button else { continue }
            button.backgroundColor = raised
            button.layer.borderColor = rule
            button.tintColor = button === streamButton ? UIColor(Ink.accent) : UIColor(Ink.ink)
        }

        refreshGradientColors()
    }

    private func refreshGradientColors() {
        let paperCG = UIColor(Ink.paper).resolvedColor(with: traitCollection).cgColor
        let clearCG = UIColor(Ink.paper).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
        fadeLayer.colors = [paperCG, clearCG]
        fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    }
}

@MainActor
final class SpikeComposerView: UIView, UITextFieldDelegate {
    var onSend: ((String, String?) -> Void)?
    var onClearQuote: (() -> Void)?

    private let fadeLayer = CAGradientLayer()
    private let confirmationPill = UIView()
    private let confirmationIcon = UIImageView()
    private let confirmationLabel = UILabel()
    private var confirmationHideWork: DispatchWorkItem?

    private let cardView = UIView()
    private let quoteContainer = UIView()
    private let quoteStripe = UIView()
    private let quoteHeaderLabel = UILabel()
    private let quoteBodyLabel = UILabel()
    private let clearQuoteButton = UIButton(type: .system)

    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)

    private var quotedText: String?
    private var quotedSpeaker: String?
    private var quoteActiveVerticalConstraints: [NSLayoutConstraint] = []
    private var quoteCollapsedConstraint: NSLayoutConstraint!

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
        clipsToBounds = false
        layer.addSublayer(fadeLayer)

        confirmationPill.alpha = 0
        confirmationPill.isHidden = true
        confirmationPill.layer.cornerCurve = .continuous
        confirmationPill.layer.borderWidth = 0.5
        confirmationPill.layer.shadowRadius = 8
        confirmationPill.layer.shadowOffset = CGSize(width: 0, height: 2)
        confirmationPill.layer.shadowOpacity = 1

        confirmationIcon.image = UIImage(systemName: "checkmark.circle.fill")
        confirmationIcon.contentMode = .scaleAspectFit
        confirmationLabel.font = UIFont.systemFont(ofSize: Ink.Size.small, weight: .medium)

        let confirmStack = UIStackView(arrangedSubviews: [confirmationIcon, confirmationLabel])
        confirmStack.axis = .horizontal
        confirmStack.alignment = .center
        confirmStack.spacing = Ink.Space.xs
        confirmStack.translatesAutoresizingMaskIntoConstraints = false
        confirmationPill.addSubview(confirmStack)
        NSLayoutConstraint.activate([
            confirmationIcon.widthAnchor.constraint(equalToConstant: 15),
            confirmationIcon.heightAnchor.constraint(equalToConstant: 15),
            confirmStack.leadingAnchor.constraint(equalTo: confirmationPill.leadingAnchor, constant: Ink.Space.m),
            confirmStack.trailingAnchor.constraint(equalTo: confirmationPill.trailingAnchor, constant: -Ink.Space.m),
            confirmStack.topAnchor.constraint(equalTo: confirmationPill.topAnchor, constant: 6),
            confirmStack.bottomAnchor.constraint(equalTo: confirmationPill.bottomAnchor, constant: -6),
        ])

        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.75
        cardView.layer.shadowRadius = 10
        cardView.layer.shadowOffset = CGSize(width: 0, height: 3)
        cardView.layer.shadowOpacity = 1

        quoteContainer.isHidden = true
        quoteContainer.clipsToBounds = true
        quoteStripe.layer.cornerRadius = 1
        quoteHeaderLabel.font = UIFont.systemFont(ofSize: Ink.Size.micro, weight: .semibold)
        quoteBodyLabel.font = UIFont.systemFont(ofSize: Ink.Size.small)
        quoteBodyLabel.numberOfLines = 3
        quoteBodyLabel.lineBreakMode = .byTruncatingTail

        clearQuoteButton.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.sub)),
            for: .normal
        )
        clearQuoteButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.clearQuote()
            self?.onClearQuote?()
        }, for: .touchUpInside)

        let quoteTextStack = UIStackView(arrangedSubviews: [quoteHeaderLabel, quoteBodyLabel])
        quoteTextStack.axis = .vertical
        quoteTextStack.spacing = 2

        let quoteRow = UIStackView(arrangedSubviews: [quoteStripe, quoteTextStack, clearQuoteButton])
        quoteRow.axis = .horizontal
        quoteRow.alignment = .top
        quoteRow.spacing = Ink.Space.s
        quoteRow.translatesAutoresizingMaskIntoConstraints = false
        quoteContainer.addSubview(quoteRow)
        quoteActiveVerticalConstraints = [
            quoteStripe.heightAnchor.constraint(equalTo: quoteTextStack.heightAnchor),
            clearQuoteButton.heightAnchor.constraint(equalToConstant: 28),
            quoteRow.topAnchor.constraint(equalTo: quoteContainer.topAnchor, constant: Ink.Space.xs),
            quoteRow.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor, constant: -Ink.Space.xs),
        ]
        quoteCollapsedConstraint = quoteContainer.heightAnchor.constraint(equalToConstant: 0)
        quoteCollapsedConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            quoteStripe.widthAnchor.constraint(equalToConstant: 2.5),
            clearQuoteButton.widthAnchor.constraint(equalToConstant: 28),
            quoteRow.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor, constant: Ink.Space.xs),
            quoteRow.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor),
            quoteCollapsedConstraint,
        ])

        inputField.font = UIFont.systemFont(ofSize: Ink.Size.sub)
        inputField.returnKeyType = .send
        inputField.clearButtonMode = .whileEditing
        inputField.delegate = self
        inputField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        let sendSize = 34 * UIScale.factor
        sendButton.setImage(
            UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.sub, weight: .semibold)),
            for: .normal
        )
        sendButton.layer.cornerRadius = sendSize * 0.5
        sendButton.addAction(UIAction { [weak self] _ in
            self?.submit()
        }, for: .touchUpInside)

        let inputRow = UIStackView(arrangedSubviews: [inputField, sendButton])
        inputRow.axis = .horizontal
        inputRow.alignment = .center
        inputRow.spacing = Ink.Space.s
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: sendSize),
            sendButton.heightAnchor.constraint(equalToConstant: sendSize),
            inputField.heightAnchor.constraint(greaterThanOrEqualToConstant: sendSize),
        ])

        let cardStack = UIStackView(arrangedSubviews: [quoteContainer, inputRow])
        cardStack.axis = .vertical
        cardStack.spacing = Ink.Space.s
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Ink.Space.m),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Ink.Space.s),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Ink.Space.s),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Ink.Space.s),
        ])

        confirmationPill.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(confirmationPill)
        addSubview(cardView)

        NSLayoutConstraint.activate([
            confirmationPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            confirmationPill.bottomAnchor.constraint(equalTo: cardView.topAnchor, constant: -Ink.Space.s),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Ink.Bar.edge),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Ink.Bar.edge),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: Ink.Space.xs),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Ink.Space.s),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SpikeComposerView, _) in
            view.refreshThemeColors()
        }
        refreshThemeColors()
        updateSendState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeLayer.frame = CGRect(x: 0, y: -Ink.Space.l, width: bounds.width, height: bounds.height + Ink.Space.l)
        confirmationPill.layer.cornerRadius = confirmationPill.bounds.height * 0.5
        cardView.layer.cornerRadius = quoteContainer.isHidden ? Ink.Radius.sheet : Ink.Radius.card
        refreshGradientColors()
    }

    func setQuote(_ excerpt: String, speaker: String) {
        quotedText = excerpt
        quotedSpeaker = speaker
        quoteHeaderLabel.text = L.format("careSpike.quotedHeaderFormat", speaker, excerpt.count)
        quoteBodyLabel.text = excerpt
        if quoteContainer.isHidden {
            quoteCollapsedConstraint.isActive = false
            quoteContainer.isHidden = false
            NSLayoutConstraint.activate(quoteActiveVerticalConstraints)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.superview?.layoutIfNeeded()
            }
        }
        updateSendState()
        showConfirmationPill(charCount: excerpt.count)
    }

    func clearQuote() {
        quotedText = nil
        quotedSpeaker = nil
        if !quoteContainer.isHidden {
            NSLayoutConstraint.deactivate(quoteActiveVerticalConstraints)
            quoteContainer.isHidden = true
            quoteCollapsedConstraint.isActive = true
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                self.superview?.layoutIfNeeded()
            }
        }
        updateSendState()
    }

    private func showConfirmationPill(charCount: Int) {
        confirmationHideWork?.cancel()
        confirmationLabel.text = L.format("careSpike.quotedToastFormat", charCount)
        confirmationPill.isHidden = false
        confirmationPill.transform = CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.confirmationPill.alpha = 1
            self.confirmationPill.transform = .identity
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.22, animations: {
                self.confirmationPill.alpha = 0
            }, completion: { _ in
                if self.confirmationPill.alpha == 0 {
                    self.confirmationPill.isHidden = true
                }
            })
        }
        confirmationHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3, execute: work)
    }

    @objc private func textChanged() {
        updateSendState()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    private func submit() {
        let draft = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty || quotedText != nil else { return }
        Haptics.light()
        let sendText = draft.isEmpty ? L.t("careSpike.defaultFollowup") : draft
        let sendQuote = quotedText
        inputField.text = ""
        clearQuote()
        inputField.resignFirstResponder()
        onSend?(sendText, sendQuote)
    }

    private func updateSendState() {
        let hasText = !(inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasText || quotedText != nil
        sendButton.isEnabled = canSend
        sendButton.backgroundColor = UIColor(canSend ? Ink.accent : Ink.mine)
        sendButton.tintColor = UIColor(canSend ? Ink.paper : Ink.inkFaint)
    }

    private func refreshThemeColors() {
        let raised = UIColor(Ink.paperRaised)
        let ruleCG = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor
        let shadowCG = UIColor(Ink.bubbleShadow).resolvedColor(with: traitCollection).cgColor

        confirmationPill.backgroundColor = raised
        confirmationPill.layer.borderColor = ruleCG
        confirmationPill.layer.shadowColor = shadowCG
        confirmationIcon.tintColor = UIColor(Ink.ok)
        confirmationLabel.textColor = UIColor(Ink.ink)

        cardView.backgroundColor = raised
        cardView.layer.borderColor = ruleCG
        cardView.layer.shadowColor = shadowCG

        quoteStripe.backgroundColor = UIColor(Ink.accent)
        quoteHeaderLabel.textColor = UIColor(Ink.accent)
        quoteBodyLabel.textColor = UIColor(Ink.inkSoft)
        clearQuoteButton.tintColor = UIColor(Ink.inkFaint)

        inputField.textColor = UIColor(Ink.ink)
        inputField.tintColor = UIColor(Ink.accent)
        inputField.attributedPlaceholder = NSAttributedString(
            string: L.t("careSpike.inputPlaceholder"),
            attributes: [.foregroundColor: UIColor(Ink.inkFaint)]
        )

        updateSendState()
        refreshGradientColors()
    }

    private func refreshGradientColors() {
        let paperCG = UIColor(Ink.paper).resolvedColor(with: traitCollection).cgColor
        let clearCG = UIColor(Ink.paper).resolvedColor(with: traitCollection).withAlphaComponent(0).cgColor
        fadeLayer.colors = [clearCG, paperCG, paperCG]
        fadeLayer.locations = [0.0, 0.28, 1.0]
        fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    }
}
#endif

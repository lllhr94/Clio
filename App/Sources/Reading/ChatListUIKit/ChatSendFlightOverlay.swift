// ChatSendFlightOverlay.swift
// Standalone Overlay Send-Bubble Fly-In View (iOS 26.0+)
// License: GPL-3.0-or-later

import QuartzCore
import UIKit

/// Lightweight standalone overlay mirroring `ChatUserCell`'s rendered bubble pixel-for-pixel using `Ink` tokens.
/// Travels from the composer area into the silently-seated target `ChatUserCell.bubbleView` using an anonymous
/// additive `position` spring (`ClioMotionPreset.sendFlight`), supporting arbitrary rapid burst sends cleanly.
@MainActor
final class ChatSendFlightOverlayView: UIView {
    private let sheenLayer = CAGradientLayer()
    private let textLabel = UILabel()

    init(entry: ChatLayoutCache.UserLayoutEntry, traits: UITraitCollection) {
        super.init(frame: CGRect(x: 0, y: 0, width: entry.bubbleWidth, height: entry.bubbleHeight))
        isUserInteractionEnabled = false
        clipsToBounds = false

        backgroundColor = UIColor(Ink.bubble)
        layer.borderWidth = 0.75
        layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traits).cgColor
        layer.shadowColor = UIColor(Ink.bubbleShadow).resolvedColor(with: traits).cgColor
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowOpacity = 1

        let cornerRadius = min(Ink.Radius.card, min(entry.bubbleWidth, entry.bubbleHeight) / 2)
        let curve: CALayerCornerCurve = entry.bubbleHeight <= 2 * Ink.Radius.card ? .circular : .continuous
        layer.cornerCurve = curve
        layer.cornerRadius = cornerRadius
        if !bounds.isEmpty {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        }

        sheenLayer.colors = [
            UIColor(Ink.bubbleSheenTop).resolvedColor(with: traits).cgColor,
            UIColor(Ink.bubbleSheenBottom).resolvedColor(with: traits).cgColor,
        ]
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 1)
        sheenLayer.frame = bounds
        sheenLayer.cornerCurve = curve
        sheenLayer.cornerRadius = cornerRadius
        layer.addSublayer(sheenLayer)

        textLabel.numberOfLines = 0
        textLabel.backgroundColor = .clear
        textLabel.attributedText = entry.rendered.attributed
        textLabel.frame = CGRect(
            x: ChatCellMetrics.userBubblePadH,
            y: ChatCellMetrics.userBubblePadV,
            width: entry.textWidth,
            height: entry.textHeight
        )
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Pure policy helper deciding whether a newly appended user message should use the standalone overlay
/// fly-in animation or degrade to the gentle `+6pt` fade / instant appearance.
enum ChatSendFlightPolicy {
    enum Mode: Equatable, Sendable {
        case overlayFlyIn
        case subtleFadeRise
        case instant
    }

    static func resolve(
        hasText: Bool,
        hasAttachments: Bool,
        reduceMotion: Bool,
        simplifyMotion: Bool
    ) -> Mode {
        guard !reduceMotion else { return .instant }
        guard hasText, !hasAttachments, !simplifyMotion else { return .subtleFadeRise }
        return .overlayFlyIn
    }
}

/// Samples geometry at the same presentation horizon for both coordinate spaces.
enum ChatMotionFrameProjection {
    static func nextValue(presented: CGFloat, model: CGFloat, now: CFTimeInterval,
                          target: CFTimeInterval, frameDuration: CFTimeInterval) -> CGFloat {
        guard presented.isFinite, model.isFinite, now.isFinite, target.isFinite,
              frameDuration.isFinite, frameDuration > 0 else { return model }
        let remaining = max(0, min(1, (target - now) / frameDuration))
        return presented + (model - presented) * CGFloat(remaining * 0.25)
    }
}

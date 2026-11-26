import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#endif

/// Configuration controlling when per-character blur/pop-in snippets run vs graceful fast-path mask reveal.
public struct RevealVisualPolicy: Equatable, Sendable {
    public var prefFade: Bool
    public var reduceMotion: Bool
    public var isLowPowerMode: Bool
    public var thermalDowngraded: Bool
    /// Derived empirically from Points cost (15pt CJK glyph * 80 clusters/s ≈ 1200 pts/s), NOT hardcoded 80 pts/s.
    public var snippetBypassPointsPerSecond: Double
    public var maxConcurrentSnippets: Int

    public init(
        prefFade: Bool = true,
        reduceMotion: Bool = false,
        isLowPowerMode: Bool = false,
        thermalDowngraded: Bool = false,
        snippetBypassPointsPerSecond: Double = 1200.0,
        maxConcurrentSnippets: Int = 48
    ) {
        self.prefFade = prefFade
        self.reduceMotion = reduceMotion
        self.isLowPowerMode = isLowPowerMode
        self.thermalDowngraded = thermalDowngraded
        self.snippetBypassPointsPerSecond = snippetBypassPointsPerSecond
        self.maxConcurrentSnippets = maxConcurrentSnippets
    }
}

public enum RevealBypassReason: String, Equatable, Sendable {
    case prefFadeDisabled
    case reduceMotionEnabled
    case lowPowerMode
    case thermalDowngraded
    case highPointsBurst
    case deltaExceededMaxSnippets
}

/// Mirrors Telegram `InstantPageRenderer.swift` `SnippetLayer` (`24638bc` L1944–1965):
/// crops a character from the backing texture and animates in (`0.20s` opacity/pos/scale + `0.22s` blur metadata).
public final class RevealSnippetLayer: CALayer {
    public let characterIndex: Int
    public let configuredBlurDuration: CFTimeInterval = 0.22
    public let configuredBlurFromRadius: CGFloat = 2.0
    public let configuredMoveScaleDuration: CFTimeInterval = 0.20

    public init(characterIndex: Int) {
        self.characterIndex = characterIndex
        super.init()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override init(layer: Any) {
        if let other = layer as? RevealSnippetLayer {
            self.characterIndex = other.characterIndex
        } else {
            self.characterIndex = 0
        }
        super.init(layer: layer)
    }
}

public struct SpikeRevealLineInfo: Equatable {
    public let lineFrame: CGRect
    public let lineHeight: CGFloat
    public let revealedWidth: CGFloat
    public let isFull: Bool
    public let isRTL: Bool
}

/// Pure `QuartzCore` adapter mirroring Telegram `computeRevealedLines`, `updateRevealMask` full-prefix merging,
/// `lowestAnimating` clamping, and clean teardown (`clearMaskAndSnippets`).
@MainActor
public final class RevealMaskCoordinator {
    private static let opaqueWhiteCGColor: CGColor = {
        let space = CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: space, components: [1.0, 1.0, 1.0, 1.0])!
    }()
    private static let clearCGColor: CGColor = {
        let space = CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: space, components: [0.0, 0.0, 0.0, 0.0])!
    }()

    public private(set) var revealMaskLayer: CALayer?
    public private(set) var revealLineMaskLayers: [CALayer] = []
    public private(set) var animatingSnippetLayers: [RevealSnippetLayer] = []
    public private(set) var previousMaxCharacterDrawCount: Int = 0
    public private(set) var lastMaskCharacterLimit: Int = 0
    public private(set) var lastBypassReason: RevealBypassReason?
    public private(set) var maskRebuildCount: Int = 0

    public init() {}

    public var activeMaskSublayerCount: Int {
        return revealLineMaskLayers.count
    }

    public var activeSnippetCount: Int {
        return animatingSnippetLayers.count
    }

    public func computeRevealedLines(
        lines: [SpikeLaidOutLine],
        characterLimit: Int,
        clippingInset: CGFloat = 4.0
    ) -> [SpikeRevealLineInfo] {
        var result: [SpikeRevealLineInfo] = []
        var remaining = characterLimit

        for line in lines {
            let localFrame = line.frame.offsetBy(dx: clippingInset, dy: clippingInset)
            let lineHeight = line.frame.size.height
            let charRects = line.characterRects

            if remaining <= 0 {
                result.append(SpikeRevealLineInfo(lineFrame: localFrame, lineHeight: lineHeight, revealedWidth: 0.0, isFull: false, isRTL: line.isRTL))
                continue
            }

            if charRects.isEmpty {
                let width = localFrame.width
                result.append(SpikeRevealLineInfo(lineFrame: localFrame, lineHeight: lineHeight, revealedWidth: width, isFull: true, isRTL: line.isRTL))
                remaining -= max(1, line.range.length)
                continue
            }

            let revealCount = min(charRects.count, remaining)
            var revealedWidth: CGFloat = 0.0
            if line.isRTL {
                var minX: CGFloat = .greatestFiniteMagnitude
                for j in 0..<revealCount {
                    let rect = charRects[j]
                    if !rect.isEmpty {
                        minX = min(minX, rect.minX)
                    }
                }
                if minX != .greatestFiniteMagnitude {
                    revealedWidth = ceil(localFrame.width - minX)
                }
            } else {
                for j in 0..<revealCount {
                    let rect = charRects[j]
                    if !rect.isEmpty {
                        revealedWidth = max(revealedWidth, rect.maxX)
                    }
                }
                revealedWidth = ceil(revealedWidth)
            }

            remaining -= charRects.count
            let isFull = remaining >= 0
            result.append(SpikeRevealLineInfo(lineFrame: localFrame, lineHeight: lineHeight, revealedWidth: revealedWidth, isFull: isFull, isRTL: line.isRTL))
        }

        return result
    }

    public func evaluateSnippetBypass(
        deltaChars: Int,
        pointsPerSecond: Double,
        policy: RevealVisualPolicy
    ) -> RevealBypassReason? {
        if !policy.prefFade { return .prefFadeDisabled }
        if policy.reduceMotion { return .reduceMotionEnabled }
        if policy.isLowPowerMode { return .lowPowerMode }
        if policy.thermalDowngraded { return .thermalDowngraded }
        if pointsPerSecond > policy.snippetBypassPointsPerSecond { return .highPointsBurst }
        if deltaChars > policy.maxConcurrentSnippets { return .deltaExceededMaxSnippets }
        return nil
    }

    public func updateRevealMask(
        hostLayer: CALayer,
        renderContainerLayer: CALayer,
        lines: [SpikeLaidOutLine],
        layerSize: CGSize,
        targetCharacterCount: Int?,
        backingContents: Any?,
        backingScale: CGFloat = 2.0,
        animateNewSegments: Bool,
        pointsPerSecond: Double = 0.0,
        policy: RevealVisualPolicy = RevealVisualPolicy(),
        clippingInset: CGFloat = 4.0
    ) {
        let effectiveCharacterDrawCount: Int
        if let explicit = targetCharacterCount {
            effectiveCharacterDrawCount = explicit
        } else {
            if previousMaxCharacterDrawCount > 0 || !animatingSnippetLayers.isEmpty {
                var total = 0
                for line in lines {
                    total += line.characterRects.isEmpty ? line.range.length : line.characterRects.count
                }
                effectiveCharacterDrawCount = total
            } else {
                clearMaskAndSnippets(renderContainerLayer: renderContainerLayer)
                previousMaxCharacterDrawCount = 0
                return
            }
        }

        let maskLayer: CALayer
        if let existing = revealMaskLayer {
            maskLayer = existing
        } else {
            maskLayer = CALayer()
            maskLayer.backgroundColor = Self.clearCGColor
            revealMaskLayer = maskLayer
            renderContainerLayer.mask = maskLayer
        }
        maskLayer.frame = CGRect(origin: .zero, size: layerSize)

        let lineInfos = computeRevealedLines(lines: lines, characterLimit: effectiveCharacterDrawCount, clippingInset: clippingInset)
        let deltaChars = max(0, effectiveCharacterDrawCount - previousMaxCharacterDrawCount)
        let bypassReason = evaluateSnippetBypass(deltaChars: deltaChars, pointsPerSecond: pointsPerSecond, policy: policy)
        lastBypassReason = bypassReason

        if previousMaxCharacterDrawCount < effectiveCharacterDrawCount,
           let contents = backingContents,
           animateNewSegments,
           bypassReason == nil,
           layerSize.width > 0.0,
           layerSize.height > 0.0 {
            let containerOrigin = renderContainerLayer.frame.origin
            var prevRem = previousMaxCharacterDrawCount
            var curRem = effectiveCharacterDrawCount
            var globalCharIdx = 0

            for i in 0..<lines.count {
                let line = lines[i]
                let info = lineInfos[i]
                let charRects = line.characterRects
                let lineCharCount = charRects.count
                let prevCount = min(max(0, prevRem), lineCharCount)
                let curCount = min(max(0, curRem), lineCharCount)
                prevRem -= lineCharCount
                curRem -= lineCharCount

                if curCount <= prevCount {
                    globalCharIdx += lineCharCount
                    continue
                }

                for j in prevCount..<curCount {
                    let charRect = charRects[j]
                    if charRect.isEmpty { continue }

                    let snippetRect = CGRect(
                        x: info.lineFrame.minX + charRect.origin.x,
                        y: info.lineFrame.minY,
                        width: max(0.5, charRect.width),
                        height: max(1.0, info.lineHeight)
                    )
                    if snippetRect.width < 0.5 { continue }

                    let contentsRect = CGRect(
                        x: snippetRect.minX / layerSize.width,
                        y: snippetRect.minY / layerSize.height,
                        width: snippetRect.width / layerSize.width,
                        height: snippetRect.height / layerSize.height
                    )

                    let snippet = RevealSnippetLayer(characterIndex: globalCharIdx + j)
                    snippet.contents = contents
                    snippet.contentsRect = contentsRect
                    snippet.contentsScale = backingScale
                    snippet.frame = snippetRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
                    hostLayer.addSublayer(snippet)
                    animatingSnippetLayers.append(snippet)

                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.0
                    fade.toValue = 1.0
                    fade.duration = snippet.configuredMoveScaleDuration
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    let rise = CABasicAnimation(keyPath: "position.y")
                    rise.fromValue = 6.0
                    rise.toValue = 0.0
                    rise.isAdditive = true
                    rise.duration = snippet.configuredMoveScaleDuration
                    rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                    scaleAnim.fromValue = 0.5
                    scaleAnim.toValue = 1.0
                    scaleAnim.duration = snippet.configuredMoveScaleDuration
                    scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    CATransaction.begin()
                    CATransaction.setCompletionBlock { [weak self, weak snippet, weak renderContainerLayer] in
                        Task { @MainActor in
                            guard let self, let snippet else { return }
                            snippet.removeFromSuperlayer()
                            self.animatingSnippetLayers.removeAll { $0 === snippet }
                            if let rc = renderContainerLayer {
                                self.rebuildMaskRectsOnly(renderContainerLayer: rc, lines: lines, targetCharacterCount: targetCharacterCount, clippingInset: clippingInset)
                            }
                        }
                    }
                    snippet.add(fade, forKey: "revealFade")
                    snippet.add(rise, forKey: "revealRise")
                    snippet.add(scaleAnim, forKey: "revealScale")
                    CATransaction.commit()
                }
                globalCharIdx += lineCharCount
            }
        }

        rebuildMaskRectsOnly(
            renderContainerLayer: renderContainerLayer,
            lines: lines,
            targetCharacterCount: targetCharacterCount,
            clippingInset: clippingInset
        )
        previousMaxCharacterDrawCount = effectiveCharacterDrawCount
    }

    public func absorbCompletedSnippets(
        renderContainerLayer: CALayer,
        lines: [SpikeLaidOutLine],
        targetCharacterCount: Int?,
        clippingInset: CGFloat = 4.0
    ) {
        for snippet in animatingSnippetLayers {
            snippet.removeAllAnimations()
            snippet.removeFromSuperlayer()
        }
        animatingSnippetLayers.removeAll()
        rebuildMaskRectsOnly(
            renderContainerLayer: renderContainerLayer,
            lines: lines,
            targetCharacterCount: targetCharacterCount,
            clippingInset: clippingInset
        )
    }

    public func clearMaskAndSnippets(renderContainerLayer: CALayer) {
        for snippet in animatingSnippetLayers {
            snippet.removeAllAnimations()
            snippet.removeFromSuperlayer()
        }
        animatingSnippetLayers.removeAll()
        for sub in revealLineMaskLayers {
            sub.removeFromSuperlayer()
        }
        revealLineMaskLayers.removeAll()
        renderContainerLayer.mask = nil
        revealMaskLayer = nil
        previousMaxCharacterDrawCount = 0
        lastMaskCharacterLimit = 0
    }

    private func rebuildMaskRectsOnly(
        renderContainerLayer: CALayer,
        lines: [SpikeLaidOutLine],
        targetCharacterCount: Int?,
        clippingInset: CGFloat
    ) {
        guard let maskLayer = revealMaskLayer else { return }

        let effectiveCount: Int
        if let explicit = targetCharacterCount {
            effectiveCount = explicit
        } else {
            var total = 0
            for line in lines {
                total += line.characterRects.isEmpty ? line.range.length : line.characterRects.count
            }
            effectiveCount = total
        }

        let maskCharacterLimit: Int
        if let lowestAnimating = animatingSnippetLayers.map(\.characterIndex).min() {
            maskCharacterLimit = lowestAnimating
        } else {
            maskCharacterLimit = effectiveCount
        }
        lastMaskCharacterLimit = maskCharacterLimit

        var maskRects: [CGRect] = []
        var pendingFullPrefix: CGRect?
        var remainingChars = maskCharacterLimit

        for line in lines {
            if remainingChars <= 0 {
                break
            }
            let localLineFrame = line.frame.offsetBy(dx: clippingInset, dy: clippingInset)
            let lineAscent = line.ascent

            let lineUnion: CGRect?
            let isFullLine: Bool
            if !line.characterRects.isEmpty {
                let revealCount = min(line.characterRects.count, remainingChars)
                isFullLine = revealCount >= line.characterRects.count
                var union: CGRect?
                for j in 0..<revealCount {
                    let rect = line.characterRects[j]
                    if rect.isEmpty { continue }
                    let glyphRect = CGRect(
                        x: localLineFrame.minX + rect.minX,
                        y: localLineFrame.minY + lineAscent - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    )
                    if let current = union {
                        union = current.union(glyphRect)
                    } else {
                        union = glyphRect
                    }
                }
                lineUnion = union
                remainingChars -= line.characterRects.count
            } else {
                lineUnion = line.range.length > 0 ? localLineFrame : nil
                isFullLine = remainingChars >= line.range.length
                remainingChars -= line.range.length
            }

            guard let lineUnion else { continue }
            if isFullLine {
                if let pending = pendingFullPrefix {
                    pendingFullPrefix = pending.union(lineUnion)
                } else {
                    pendingFullPrefix = lineUnion
                }
            } else {
                if let pending = pendingFullPrefix {
                    maskRects.append(pending)
                    pendingFullPrefix = nil
                }
                maskRects.append(lineUnion)
            }
        }
        if let pending = pendingFullPrefix {
            maskRects.append(pending)
        }

        while revealLineMaskLayers.count < maskRects.count {
            let child = CALayer()
            child.backgroundColor = Self.opaqueWhiteCGColor
            maskLayer.addSublayer(child)
            revealLineMaskLayers.append(child)
        }
        while revealLineMaskLayers.count > maskRects.count {
            let removed = revealLineMaskLayers.removeLast()
            removed.removeFromSuperlayer()
        }
        for i in 0..<maskRects.count {
            revealLineMaskLayers[i].frame = maskRects[i]
        }
        maskRebuildCount += 1

        if targetCharacterCount == nil && animatingSnippetLayers.isEmpty {
            renderContainerLayer.mask = nil
            revealMaskLayer = nil
            for sub in revealLineMaskLayers { sub.removeFromSuperlayer() }
            revealLineMaskLayers.removeAll()
        }
    }
}

#if canImport(UIKit)
/// Native UIKit view rendering CoreText lines into a `CGImage` texture and driving `RevealMaskCoordinator`
/// for iOS Simulator validation of `CALayer` mask + `RevealSnippetLayer` behavior.
@MainActor
public final class SpikeRevealTextView: UIView {
    public let renderContainer = UIView()
    public let renderLayer = CALayer()
    public let coordinator = RevealMaskCoordinator()
    public private(set) var laidOutLines: [SpikeLaidOutLine] = []
    public private(set) var contentSize: CGSize = .zero
    public var policy = RevealVisualPolicy()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        renderContainer.backgroundColor = .clear
        renderContainer.layer.addSublayer(renderLayer)
        addSubview(renderContainer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(attributed: NSAttributedString, maxWidth: CGFloat) -> CoreTextRevealMeasurer.LayoutResult {
        let layout = CoreTextRevealMeasurer.layoutText(attributed, maxWidth: maxWidth)
        self.laidOutLines = layout.lines
        let paddedSize = CGSize(width: layout.contentSize.width + 8.0, height: layout.contentSize.height + 8.0)
        self.contentSize = paddedSize
        self.bounds = CGRect(origin: .zero, size: paddedSize)
        self.renderContainer.frame = bounds
        self.renderLayer.frame = bounds

        let scale = window?.screen.scale ?? 2.0
        if let cgImage = CoreTextRevealMeasurer.rasterizeBackingImage(lines: layout.lines, size: paddedSize, scale: scale, padding: 4.0) {
            renderLayer.contents = cgImage
            renderLayer.contentsScale = scale
        }
        return layout
    }

    public func applyReveal(characterCount: Int?, animateNewSegments: Bool, pointsPerSecond: Double) {
        coordinator.updateRevealMask(
            hostLayer: layer,
            renderContainerLayer: renderContainer.layer,
            lines: laidOutLines,
            layerSize: renderContainer.bounds.size,
            targetCharacterCount: characterCount,
            backingContents: renderLayer.contents,
            backingScale: renderLayer.contentsScale,
            animateNewSegments: animateNewSegments,
            pointsPerSecond: pointsPerSecond,
            policy: policy,
            clippingInset: 4.0
        )
    }
}
#endif

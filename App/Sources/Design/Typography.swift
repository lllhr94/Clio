import CoreText
import Foundation
import UIKit

/// Internal optical compensation profile per face so visual x-height, stroke weight,
/// and tracking stay consistent across faces without exposing extra user knobs.
struct FontOpticalProfile: Equatable, Sendable {
    let id: String
    let opticalScale: CGFloat
    let lhOffset: CGFloat
    let trackingEm: CGFloat
    let proseBoldStroke: CGFloat
    let tableBoldStroke: CGFloat

    nonisolated static func resolve(for face: Pref.Face) -> FontOpticalProfile {
        switch face {
        case .wenkai:
            return FontOpticalProfile(
                id: "clioKaiMedium",
                opticalScale: 1.045,
                lhOffset: 0.0,
                trackingEm: 0.002,
                proseBoldStroke: -2.2,
                tableBoldStroke: -1.8
            )
        case .song:
            return FontOpticalProfile(
                id: "stSongtiSC",
                opticalScale: 1.03,
                lhOffset: 0.0,
                trackingEm: 0.002,
                proseBoldStroke: 0.0,
                tableBoldStroke: 0.0
            )
        case .kai:
            return FontOpticalProfile(
                id: "stKaitiSC",
                opticalScale: 1.03,
                lhOffset: 0.0,
                trackingEm: 0.002,
                proseBoldStroke: 0.0,
                tableBoldStroke: 0.0
            )
        case .serif, .sans, .rounded:
            return FontOpticalProfile(
                id: "systemProse",
                opticalScale: 1.0,
                lhOffset: 0.0,
                trackingEm: -0.004,
                proseBoldStroke: 0.0,
                tableBoldStroke: 0.0
            )
        }
    }

    /// Synthetic heading bold stroke for single-weight custom faces (only applies to 文楷).
    nonisolated func headingStroke(weight: Pref.HeadingWeight) -> CGFloat {
        guard proseBoldStroke != 0 else { return 0 }
        switch weight {
        case .medium: return -1.5
        case .semibold: return -2.2
        case .bold: return -2.8
        }
    }
}

/// Single-source line-box metrics eliminating stacked `minimumLineHeight + lineSpacing`
/// while preserving organic vertical expansion (`maximumLineHeight = 0`) for tall Emoji/math.
struct SafeLineBoxMetrics: Equatable, Sendable {
    let userReadingSize: CGFloat
    let effectivePointSize: CGFloat
    let naturalBoxHeight: CGFloat
    let targetLineHeight: CGFloat
    let minimumLineHeight: CGFloat
    let maximumLineHeight: CGFloat
    let lineSpacing: CGFloat
    let trackingPoints: CGFloat

    /// SwiftUI `.lineSpacing(...)` bridge derived cleanly from the resolved minimum line height.
    nonisolated var swiftUILineSpacing: CGFloat {
        max(0, minimumLineHeight - naturalBoxHeight)
    }

    nonisolated func makeParagraphStyle(
        spacing: CGFloat = 0,
        before: CGFloat = 0,
        indent: CGFloat = 0,
        hanging: CGFloat = 0,
        tailIndent: CGFloat = 0,
        alignment: NSTextAlignment = .natural
    ) -> NSParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.minimumLineHeight = minimumLineHeight
        pStyle.maximumLineHeight = maximumLineHeight // Always 0 so tall Emoji/math lines grow cleanly.
        pStyle.lineSpacing = lineSpacing             // Always 0 so lineSpacing never stacks on minimumLineHeight.
        pStyle.paragraphSpacing = spacing
        pStyle.paragraphSpacingBefore = before
        pStyle.firstLineHeadIndent = indent
        pStyle.headIndent = indent + hanging
        pStyle.alignment = alignment
        if tailIndent != 0 { pStyle.tailIndent = tailIndent }
        if hanging > 0 {
            pStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)]
        }
        return (pStyle.copy() as? NSParagraphStyle) ?? pStyle
    }
}

/// Single source of truth for Clio DS 2.0 typography scale, optical compensation, and safe line boxes.
enum SafeLineBox {
    nonisolated static let tableMultiplier: CGFloat = 1.40
    nonisolated static let codeMultiplier: CGFloat = 1.30

    nonisolated static func effectivePointSize(for userSize: CGFloat, face: Pref.Face) -> CGFloat {
        let scale = FontOpticalProfile.resolve(for: face).opticalScale
        return (userSize * scale * 2.0).rounded() / 2.0
    }

    nonisolated static func resolve(
        userSize: CGFloat,
        contentMultiplier: CGFloat,
        face: Pref.Face,
        font: UIFont? = nil
    ) -> SafeLineBoxMetrics {
        let profile = FontOpticalProfile.resolve(for: face)
        let effectivePt = effectivePointSize(for: userSize, face: face)
        let resolvedFont = font ?? Ink.uiFace(effectivePt, weight: .regular, face: face)
        let naturalBox = ceil(resolvedFont.ascender - resolvedFont.descender)
        let targetLineHeight = userSize * contentMultiplier + profile.lhOffset
        let minLineHeight = max(targetLineHeight, naturalBox)

        return SafeLineBoxMetrics(
            userReadingSize: userSize,
            effectivePointSize: effectivePt,
            naturalBoxHeight: naturalBox,
            targetLineHeight: targetLineHeight,
            minimumLineHeight: minLineHeight,
            maximumLineHeight: 0,
            lineSpacing: 0,
            trackingPoints: effectivePt * profile.trackingEm
        )
    }

    nonisolated static func userBubbleMultiplier(for userLineHeight: CGFloat) -> CGFloat {
        max(1.42, min(userLineHeight, 1.55))
    }

    nonisolated static func listMultiplier(for userLineHeight: CGFloat) -> CGFloat {
        max(1.35, min(userLineHeight - 0.15, 1.55))
    }

    nonisolated static func quoteMultiplier(for userLineHeight: CGFloat) -> CGFloat {
        min(1.85, userLineHeight + 0.05)
    }

    nonisolated static func headingMultiplier(level: Int) -> CGFloat {
        if level <= 1 { return 1.32 }
        if level == 2 { return 1.35 }
        if level == 3 { return 1.42 }
        return 1.45
    }

    nonisolated static func headingSize(level: Int, readingSize: CGFloat) -> CGFloat {
        if level <= 1 { return (readingSize * 1.26 * 2.0).rounded() / 2.0 }
        if level == 2 { return (readingSize * 1.12 * 2.0).rounded() / 2.0 }
        return readingSize
    }

    nonisolated static func headingTop(level: Int, readingSize: CGFloat) -> CGFloat {
        if level <= 1 { return readingSize * 1.0 }
        if level == 2 { return readingSize * 0.85 }
        if level == 3 { return readingSize * 0.62 }
        return readingSize * 0.45
    }

    nonisolated static func headingBottom(level: Int, readingSize: CGFloat) -> CGFloat {
        if level <= 1 { return readingSize * 0.36 }
        if level == 2 { return readingSize * 0.30 }
        if level == 3 { return readingSize * 0.22 }
        return readingSize * 0.16
    }
}

/// Applies W3C CLREQ optical CJK–Latin spacing and consecutive fullwidth punctuation compression
/// strictly in the render-layer `NSAttributedString` without mutating raw strings or clipboard text.
enum ClioMixedScriptKerning {
    private static let closingPunctuation: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？", "）", "》", "」", "』", "】",
    ]
    private static let openingPunctuation: Set<Character> = [
        "（", "《", "「", "『", "【",
    ]

    nonisolated static func apply(
        to attributed: NSMutableAttributedString,
        fontSize: CGFloat,
        squeezePunctuation: Bool,
        skipAttributeKeys: [NSAttributedString.Key] = [],
        ratio: CGFloat = 0.15
    ) {
        let text = attributed.string
        let totalLength = attributed.length
        guard totalLength > 1, !text.isEmpty else { return }

        let kernPoints = Double((fontSize * ratio * 100.0).rounded() / 100.0)
        let squeezePoints = -Double((fontSize * 0.32 * 100.0).rounded() / 100.0)
        let utf16 = text.utf16

        func utf16Offset(_ index: String.Index) -> Int? {
            guard let pos = index.samePosition(in: utf16) else { return nil }
            return utf16.distance(from: utf16.startIndex, to: pos)
        }

        func isProtected(at offset: Int) -> Bool {
            guard offset >= 0, offset < totalLength else { return false }
            if attributed.attribute(.link, at: offset, effectiveRange: nil) != nil {
                return true
            }
            for key in skipAttributeKeys {
                if attributed.attribute(key, at: offset, effectiveRange: nil) != nil {
                    return true
                }
            }
            return false
        }

        var prevIndex: String.Index?
        var prevChar: Character?

        attributed.beginEditing()
        defer { attributed.endEditing() }

        for idx in text.indices {
            let current = text[idx]
            if let pIdx = prevIndex, let pChar = prevChar {
                let prevOffset = utf16Offset(pIdx)
                let curOffset = utf16Offset(idx)
                if let prevOffset, let curOffset,
                   !isProtected(at: prevOffset),
                   !isProtected(at: curOffset) {
                    let utf16Range = NSRange(pIdx..<idx, in: text)
                    if utf16Range.length > 0 && utf16Range.location + utf16Range.length <= totalLength {
                        var delta: Double = 0
                        if !isExplicitSpace(pChar) && !isExplicitSpace(current) && isMixedBoundary(pChar, current) {
                            delta = kernPoints
                        } else if squeezePunctuation && isConsecutivePunctuation(pChar, current) {
                            delta = squeezePoints
                        }
                        if delta != 0 {
                            let existing = (attributed.attribute(.kern, at: utf16Range.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0.0
                            attributed.addAttribute(.kern, value: NSNumber(value: existing + delta), range: utf16Range)
                        }
                    }
                }
            }
            prevIndex = idx
            prevChar = current
        }
    }

    nonisolated private static func isConsecutivePunctuation(_ a: Character, _ b: Character) -> Bool {
        if closingPunctuation.contains(a) && (closingPunctuation.contains(b) || openingPunctuation.contains(b)) {
            return true
        }
        if openingPunctuation.contains(a) && openingPunctuation.contains(b) {
            return true
        }
        return false
    }

    nonisolated private static func isExplicitSpace(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0x00A0 || scalar.value == 0x3000 {
                return true
            }
        }
        return false
    }

    nonisolated private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0x20000...0x2EBEF).contains(v) {
                return true
            }
        }
        return false
    }

    nonisolated private static func isASCIIWord(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x0030...0x0039).contains(v)
                || (0x0041...0x005A).contains(v)
                || (0x0061...0x007A).contains(v) {
                return true
            }
        }
        return false
    }

    nonisolated private static func isMixedBoundary(_ a: Character, _ b: Character) -> Bool {
        (isCJK(a) && isASCIIWord(b)) || (isASCIIWord(a) && isCJK(b))
    }
}

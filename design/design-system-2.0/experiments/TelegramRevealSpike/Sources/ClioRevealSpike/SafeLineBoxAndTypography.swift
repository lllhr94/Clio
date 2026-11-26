import CoreText
import Foundation

#if canImport(UIKit)
import UIKit
public typealias SpikePlatformColor = UIColor
public typealias SpikePlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
public typealias SpikePlatformColor = NSColor
public typealias SpikePlatformFont = NSFont
#endif

/// Optical compensation profile digested internally by `SafeLineBox` without adding user settings.
public struct FontOpticalProfile: Equatable, Sendable {
    public let id: String
    public let opticalScale: CGFloat
    public let lhOffset: CGFloat
    public let trackingEm: CGFloat
    public let proseBoldStroke: CGFloat
    public let tableBoldStroke: CGFloat

    public init(
        id: String,
        opticalScale: CGFloat,
        lhOffset: CGFloat,
        trackingEm: CGFloat,
        proseBoldStroke: CGFloat,
        tableBoldStroke: CGFloat
    ) {
        self.id = id
        self.opticalScale = opticalScale
        self.lhOffset = lhOffset
        self.trackingEm = trackingEm
        self.proseBoldStroke = proseBoldStroke
        self.tableBoldStroke = tableBoldStroke
    }

    public static let systemProse = FontOpticalProfile(
        id: "systemProse",
        opticalScale: 1.0,
        lhOffset: 0.0,
        trackingEm: -0.004,
        proseBoldStroke: 0.0,
        tableBoldStroke: 0.0
    )

    public static let clioKaiMedium = FontOpticalProfile(
        id: "clioKaiMedium",
        opticalScale: 1.045,
        lhOffset: 0.0,
        trackingEm: 0.002,
        proseBoldStroke: -2.2,
        tableBoldStroke: -1.8
    )

    public static let monoCode = FontOpticalProfile(
        id: "monoCode",
        opticalScale: 1.0,
        lhOffset: 0.0,
        trackingEm: 0.0,
        proseBoldStroke: 0.0,
        tableBoldStroke: 0.0
    )
}

/// Unified typography and line-box output shared across AI prose, user bubbles, streaming, and settled text.
public struct SafeLineBoxMetrics: Equatable {
    public let userReadingSize: CGFloat
    public let effectivePointSize: CGFloat
    public let naturalBoxHeight: CGFloat
    public let targetLineHeight: CGFloat
    public let minimumLineHeight: CGFloat
    public let maximumLineHeight: CGFloat
    public let lineSpacing: CGFloat
    public let trackingPoints: CGFloat
    public let fallbackSafePaddingApplied: CGFloat

    public func makeParagraphStyle(paragraphSpacing: CGFloat = 0.0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = minimumLineHeight
        style.maximumLineHeight = maximumLineHeight // Always 0 so tall Emoji/math lines grow organically.
        style.lineSpacing = lineSpacing             // Always 0 so lineSpacing never stacks on minimumLineHeight.
        style.paragraphSpacing = paragraphSpacing
        return style
    }
}

public enum SafeLineBox {
    /// Computes single-source-of-truth line-box metrics with zero double lineSpacing and zero unconditional +2pt padding.
    public static func resolve(
        userReadingSize: CGFloat,
        contentMultiplier: CGFloat,
        fontForNaturalBox font: CTFont,
        profile: FontOpticalProfile
    ) -> SafeLineBoxMetrics {
        let scaled = userReadingSize * profile.opticalScale
        let effectivePt = (scaled * 2.0).rounded() / 2.0
        let naturalBox = ceil(CTFontGetAscent(font) + CTFontGetDescent(font))
        let targetLineHeight = userReadingSize * contentMultiplier + profile.lhOffset
        let minLineHeight = max(targetLineHeight, naturalBox)

        return SafeLineBoxMetrics(
            userReadingSize: userReadingSize,
            effectivePointSize: effectivePt,
            naturalBoxHeight: naturalBox,
            targetLineHeight: targetLineHeight,
            minimumLineHeight: minLineHeight,
            maximumLineHeight: 0.0,
            lineSpacing: 0.0,
            trackingPoints: effectivePt * profile.trackingEm,
            fallbackSafePaddingApplied: 0.0
        )
    }
}

/// Loads real bundled Clio TTF fonts directly from `<repo>/App/Fonts/` via CoreText without modifying `App/`.
public enum ClioFontLoader {
    public static func locateRepoRoot(callerFile: String = #filePath) -> URL? {
        if let envRoot = ProcessInfo.processInfo.environment["CLIO_REPO_ROOT"], !envRoot.isEmpty {
            let candidate = URL(fileURLWithPath: envRoot, isDirectory: true)
            let marker = candidate.appendingPathComponent("App/Fonts/ClioKai-Medium.ttf")
            if FileManager.default.fileExists(atPath: marker.path) {
                return candidate
            }
        }
        var current = URL(fileURLWithPath: callerFile).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = current.appendingPathComponent("App/Fonts/ClioKai-Medium.ttf")
            if FileManager.default.fileExists(atPath: marker.path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    public static func fontURL(named fileName: String, repoRoot: URL? = nil, callerFile: String = #filePath) -> URL? {
        guard let root = repoRoot ?? locateRepoRoot(callerFile: callerFile) else {
            return nil
        }
        let url = root.appendingPathComponent("App/Fonts/\(fileName)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    public static func loadBundledFont(
        named fileName: String,
        size: CGFloat,
        repoRoot: URL? = nil,
        callerFile: String = #filePath
    ) -> CTFont? {
        guard let url = fontURL(named: fileName, repoRoot: repoRoot, callerFile: callerFile),
              let rawDescriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = rawDescriptors.first else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    public static func loadMapleWithChinese(
        size: CGFloat,
        bold: Bool = false,
        repoRoot: URL? = nil,
        callerFile: String = #filePath
    ) -> CTFont? {
        let mapleName = bold ? "MapleMono-SemiBold.ttf" : "MapleMono-Regular.ttf"
        guard let latin = loadBundledFont(named: mapleName, size: size, repoRoot: repoRoot, callerFile: callerFile),
              let cn = loadBundledFont(named: "ClioMonoCN-Regular.ttf", size: size, repoRoot: repoRoot, callerFile: callerFile) else {
            return nil
        }
        let cnDescriptor = CTFontCopyFontDescriptor(cn)
        let baseDescriptor = CTFontCopyFontDescriptor(latin)
        let attrs: [CFString: Any] = [kCTFontCascadeListAttribute: [cnDescriptor]]
        let combined = CTFontDescriptorCreateCopyWithAttributes(baseDescriptor, attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(combined, size, nil)
    }

    public static func systemReadingFont(size: CGFloat) -> CTFont {
        return CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }
}

/// Applies W3C CLREQ optical CJK-Latin kerning in the rendering layer without mutating raw strings
/// and strictly skipping boundaries that already contain a literal whitespace character.
public enum ClioMixedScriptKerning {
    public static func apply(
        to attributed: NSMutableAttributedString,
        fontSize: CGFloat,
        ratio: CGFloat = 0.16
    ) {
        let text = attributed.string
        guard !text.isEmpty else { return }

        let kernPoints = (fontSize * ratio * 100.0).rounded() / 100.0
        var prevIndex: String.Index?
        var prevChar: Character?

        attributed.beginEditing()
        defer { attributed.endEditing() }

        for idx in text.indices {
            let current = text[idx]
            if let pIdx = prevIndex, let pChar = prevChar {
                if !isExplicitSpace(pChar) && !isExplicitSpace(current) && isMixedBoundary(pChar, current) {
                    let utf16Range = NSRange(pIdx..<idx, in: text)
                    if utf16Range.length > 0 {
                        let existing = (attributed.attribute(.kern, at: utf16Range.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0.0
                        attributed.addAttribute(.kern, value: NSNumber(value: existing + Double(kernPoints)), range: utf16Range)
                    }
                }
            }
            prevIndex = idx
            prevChar = current
        }
    }

    private static func isExplicitSpace(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0x00A0 || scalar.value == 0x3000 {
                return true
            }
        }
        return false
    }

    private static func isCJK(_ ch: Character) -> Bool {
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

    private static func isASCIIWord(_ ch: Character) -> Bool {
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

    private static func isMixedBoundary(_ a: Character, _ b: Character) -> Bool {
        return (isCJK(a) && isASCIIWord(b)) || (isASCIIWord(a) && isCJK(b))
    }
}

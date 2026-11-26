import AgentKit
import CoreText
import Craft
import SwiftUI
import UIKit

/// Pre-resolved concrete `UIColor`s for off-main-thread layout, prose rendering, and CoreText tile rasterization.
struct ChatResolvedColors: Equatable, @unchecked Sendable {
    let ink: UIColor
    let inkSoft: UIColor
    let inkFaint: UIColor
    let accent: UIColor
    let paper: UIColor
    let paperRaised: UIColor
    let rule: UIColor
    let mine: UIColor
    let accentWash: UIColor
    let codeOutput: UIColor
    let codeKeyword: UIColor
    let codeFunction: UIColor
    let codeNumber: UIColor
    let codeString: UIColor
    let inlineCodeFill: UIColor
    let ruleFill: UIColor
    let quoteBackground: UIColor
    let quoteBorder: UIColor
    let quoteStripe: UIColor

    @MainActor
    static func resolve(traits: UITraitCollection) -> ChatResolvedColors {
        func pick(_ color: Color) -> UIColor {
            UIColor(color).resolvedColor(with: traits)
        }
        let mine = pick(Ink.mine)
        let rule = pick(Ink.rule)
        let paperRaised = pick(Ink.paperRaised)
        let accent = pick(Ink.accent)
        let surfaceSubtle = pick(Ink.surfaceSubtle)
        return ChatResolvedColors(
            ink: pick(Ink.ink),
            inkSoft: pick(Ink.inkSoft),
            inkFaint: pick(Ink.inkFaint),
            accent: accent,
            paper: pick(Ink.paper),
            paperRaised: paperRaised,
            rule: rule,
            mine: mine,
            accentWash: pick(Ink.accentWash),
            codeOutput: pick(Ink.Code.output),
            codeKeyword: pick(Ink.Code.keyword),
            codeFunction: pick(Ink.Code.function),
            codeNumber: pick(Ink.Code.number),
            codeString: pick(Ink.Code.string),
            inlineCodeFill: surfaceSubtle,
            ruleFill: rule.withAlphaComponent(0.85),
            quoteBackground: surfaceSubtle.withAlphaComponent(0.35),
            quoteBorder: .clear,
            quoteStripe: accent.withAlphaComponent(0.55)
        )
    }
}

/// Pre-resolved immutable geometry and typography spacing metrics for off-main-thread layout calculation.
struct ChatResolvedMetrics: Equatable, Sendable {
    let scale: CGFloat
    let spaceXS: CGFloat
    let spaceS: CGFloat
    let spaceM: CGFloat
    let spaceL: CGFloat
    let spaceXL: CGFloat
    let spaceXXL: CGFloat
    let spacePage: CGFloat
    let spaceHuge: CGFloat
    let radiusSmall: CGFloat
    let sizeMicro: CGFloat
    let sizeSmall: CGFloat
    let sizeSub: CGFloat
    let sizeBody: CGFloat
    let sizeTitle: CGFloat
    let readingSize: CGFloat
    let codeSize: CGFloat
    let inlineCodeSize: CGFloat
    let tableCellSize: CGFloat
    let rowSpacing: CGFloat
    let sectionSpacing: CGFloat
    let userTurnTopPad: CGFloat
    let faceSize: CGFloat
    let compactSpeakerSize: CGFloat
    let timeGapHeight: CGFloat
    let timeGapBottomPad: CGFloat
    let photoSize: CGFloat
    let userBubblePadH: CGFloat
    let userBubblePadV: CGFloat
    let botBlockGap: CGFloat
    let disclosureHeaderHeight: CGFloat
    let disclosureGap: CGFloat
    let sourcesPillHeight: CGFloat
    let continueButtonHeight: CGFloat
    let footerHeight: CGFloat
    let queuedActionsHeight: CGFloat
    let leading: CGFloat
    let paragraphGap: CGFloat
    let listSpacing: CGFloat
    let headingBottom: CGFloat
    let codeLineSpacing: CGFloat
    let codeHeaderHeight: CGFloat
    let codeFoldButtonHeight: CGFloat
    let inlineCodeCorner: CGFloat
    let opticalProfile: FontOpticalProfile
    let bodyBox: SafeLineBoxMetrics
    let userBox: SafeLineBoxMetrics
    let listBox: SafeLineBoxMetrics
    let quoteBox: SafeLineBoxMetrics
    let h1Box: SafeLineBoxMetrics
    let h2Box: SafeLineBoxMetrics
    let h3Box: SafeLineBoxMetrics
    let h4Box: SafeLineBoxMetrics
    let tableBox: SafeLineBoxMetrics
    let codeBox: SafeLineBoxMetrics
    let headingWeight: Pref.HeadingWeight
    let clreqSqueeze: Bool
    let readingWidth: CGFloat

    @MainActor
    static func resolve(
        size: Double,
        lineHeight: Double,
        paragraphGap: Double,
        headingWeight: Pref.HeadingWeight,
        clreqSqueeze: Bool,
        readingWidth: Double,
        face: Pref.Face,
        code: Pref.Code,
        uiScale: Double
    ) -> ChatResolvedMetrics {
        let scale = CGFloat(uiScale)
        let readingSize = CGFloat(size)
        let userLH = CGFloat(lineHeight)
        let codeSize = max(CGFloat(12), readingSize - 3)
        let inlineCodeSize = max(CGFloat(12), readingSize - 2)
        let profile = FontOpticalProfile.resolve(for: face)

        let bodyBox = SafeLineBox.resolve(userSize: readingSize, contentMultiplier: userLH, face: face)
        let userBox = SafeLineBox.resolve(userSize: readingSize, contentMultiplier: SafeLineBox.userBubbleMultiplier(for: userLH), face: face)
        let listBox = SafeLineBox.resolve(userSize: readingSize, contentMultiplier: SafeLineBox.listMultiplier(for: userLH), face: face)
        let quoteBox = SafeLineBox.resolve(userSize: max(13, readingSize - 0.5), contentMultiplier: SafeLineBox.quoteMultiplier(for: userLH), face: face)

        func makeHeadingBox(_ level: Int, weight: UIFont.Weight) -> SafeLineBoxMetrics {
            let hUserSize = SafeLineBox.headingSize(level: level, readingSize: readingSize)
            let hEffectivePt = SafeLineBox.effectivePointSize(for: hUserSize, face: face)
            let hFont = Ink.uiFace(hEffectivePt, weight: weight, face: face)
            return SafeLineBox.resolve(
                userSize: hUserSize,
                contentMultiplier: SafeLineBox.headingMultiplier(level: level),
                face: face,
                font: hFont
            )
        }

        let h1Box = makeHeadingBox(1, weight: headingWeight.uiWeight)
        let h2Box = makeHeadingBox(2, weight: headingWeight.uiWeight)
        let h3Box = makeHeadingBox(3, weight: headingWeight.uiWeight)
        let h4Box = makeHeadingBox(4, weight: .medium)
        let tableBox = SafeLineBox.resolve(userSize: inlineCodeSize, contentMultiplier: SafeLineBox.tableMultiplier, face: face)

        let codeFont = Ink.uiMono(codeSize, preference: code)
        let codeNatural = ceil(codeFont.ascender - codeFont.descender)
        let codeTarget = codeSize * SafeLineBox.codeMultiplier
        let codeBox = SafeLineBoxMetrics(
            userReadingSize: codeSize,
            effectivePointSize: codeSize,
            naturalBoxHeight: codeNatural,
            targetLineHeight: codeTarget,
            minimumLineHeight: max(codeTarget, codeNatural),
            maximumLineHeight: 0,
            lineSpacing: 0,
            trackingPoints: 0
        )

        return ChatResolvedMetrics(
            scale: scale,
            spaceXS: Ink.Space.xs,
            spaceS: Ink.Space.s,
            spaceM: Ink.Space.m,
            spaceL: Ink.Space.l,
            spaceXL: Ink.Space.xl,
            spaceXXL: Ink.Space.xxl,
            spacePage: Ink.Space.page,
            spaceHuge: Ink.Space.huge,
            radiusSmall: Ink.Radius.small,
            sizeMicro: Ink.Size.micro,
            sizeSmall: Ink.Size.small,
            sizeSub: Ink.Size.sub,
            sizeBody: Ink.Size.body,
            sizeTitle: Ink.Size.title,
            readingSize: readingSize,
            codeSize: codeSize,
            inlineCodeSize: inlineCodeSize,
            tableCellSize: inlineCodeSize,
            rowSpacing: ChatCellMetrics.rowSpacing,
            sectionSpacing: ChatCellMetrics.sectionSpacing,
            userTurnTopPad: ChatCellMetrics.userTurnTopPad,
            faceSize: ChatCellMetrics.faceSize,
            compactSpeakerSize: ChatCellMetrics.compactSpeakerSize,
            timeGapHeight: ChatCellMetrics.timeGapHeight,
            timeGapBottomPad: ChatCellMetrics.timeGapBottomPad,
            photoSize: ChatCellMetrics.photoSize,
            userBubblePadH: ChatCellMetrics.userBubblePadH,
            userBubblePadV: ChatCellMetrics.userBubblePadV,
            botBlockGap: ChatCellMetrics.botBlockGap,
            disclosureHeaderHeight: ChatCellMetrics.disclosureHeaderHeight,
            disclosureGap: ChatCellMetrics.disclosureGap,
            sourcesPillHeight: ChatCellMetrics.sourcesPillHeight,
            continueButtonHeight: ChatCellMetrics.continueButtonHeight,
            footerHeight: ChatCellMetrics.footerHeight,
            queuedActionsHeight: 24 * scale,
            leading: bodyBox.swiftUILineSpacing,
            paragraphGap: CGFloat(paragraphGap),
            listSpacing: readingSize * 0.25,
            headingBottom: SafeLineBox.headingBottom(level: 1, readingSize: readingSize),
            codeLineSpacing: max(1.5, codeSize * 0.13),
            codeHeaderHeight: 32 * scale,
            codeFoldButtonHeight: 34 * scale,
            inlineCodeCorner: 5 * scale,
            opticalProfile: profile,
            bodyBox: bodyBox,
            userBox: userBox,
            listBox: listBox,
            quoteBox: quoteBox,
            h1Box: h1Box,
            h2Box: h2Box,
            h3Box: h3Box,
            h4Box: h4Box,
            tableBox: tableBox,
            codeBox: codeBox,
            headingWeight: headingWeight,
            clreqSqueeze: clreqSqueeze,
            readingWidth: CGFloat(readingWidth)
        )
    }

    nonisolated func headingBox(level: Int) -> SafeLineBoxMetrics {
        if level <= 1 { return h1Box }
        if level == 2 { return h2Box }
        if level == 3 { return h3Box }
        return h4Box
    }

    nonisolated func headingSize(level: Int) -> CGFloat {
        SafeLineBox.headingSize(level: level, readingSize: readingSize)
    }

    nonisolated func headingTop(level: Int) -> CGFloat {
        SafeLineBox.headingTop(level: level, readingSize: readingSize)
    }

    nonisolated func headingBottom(level: Int) -> CGFloat {
        SafeLineBox.headingBottom(level: level, readingSize: readingSize)
    }

    nonisolated func effectiveContentWidth(for collectionWidth: CGFloat) -> CGFloat {
        let available = max(120, collectionWidth - spacePage * 2)
        return available > readingWidth ? readingWidth : available
    }
}

/// Pre-resolved UIFont variants (regular/bold/italic/boldItalic/inlineCode) for a single text tier.
struct ChatFontGroup: Equatable, @unchecked Sendable {
    let regular: UIFont
    let bold: UIFont
    let italic: UIFont
    let boldItalic: UIFont
    let inlineCode: UIFont

    @MainActor
    static func resolve(
        size: CGFloat,
        face: Pref.Face,
        code: Pref.Code,
        regularWeight: UIFont.Weight = .regular,
        boldWeight: UIFont.Weight = .semibold
    ) -> ChatFontGroup {
        let regular = Ink.uiFace(size, weight: regularWeight, face: face)
        let bold = Ink.uiFace(size, weight: boldWeight, face: face)
        let italic = ChatResolvedFonts.italicized(regular, size: size)
        let boldItalic = ChatResolvedFonts.italicized(bold, size: size)
        let inlineCode = Ink.uiMono(max(CGFloat(12), size - 2), preference: code)
        return ChatFontGroup(
            regular: regular,
            bold: bold,
            italic: italic,
            boldItalic: boldItalic,
            inlineCode: inlineCode
        )
    }
}

/// Pre-resolved concrete `UIFont`s snapshotted on `@MainActor` so background layout never touches `Ink.uiFace`/`Ink.uiMono`.
struct ChatResolvedFonts: Equatable, @unchecked Sendable {
    private struct AlignedPair: Equatable, @unchecked Sendable {
        let narrow: UIFont
        let wide: UIFont
    }

    private struct AlignedPairKey: Hashable, Sendable {
        let sizeKey: Int
        let codePref: Pref.Code
        let italic: Bool
    }

    private static let alignedPairCache = BoundedLRUCache<AlignedPairKey, AlignedPair>(countLimit: 24)

    let reading: ChatFontGroup
    let heading1: ChatFontGroup
    let heading2: ChatFontGroup
    let heading3: ChatFontGroup
    let heading4: ChatFontGroup
    let quote: ChatFontGroup
    let table: ChatFontGroup
    let tableNumericRegular: UIFont
    let tableNumericBold: UIFont
    let userBody: UIFont
    let disclosureSmall: UIFont
    let ruleMicro: UIFont
    let listNumberMarker: UIFont
    let listBulletDepth0: UIFont
    let listBulletDepthNested: UIFont
    let codePlainRegular: UIFont
    let codePlainItalic: UIFont
    let codeAlignedRegularNarrow: UIFont
    let codeAlignedRegularWide: UIFont
    let codeAlignedItalicNarrow: UIFont
    let codeAlignedItalicWide: UIFont
    let noteAdviceTitle: UIFont
    let noteAdviceDetail: UIFont
    let notePlain: UIFont
    let queuedMessage: UIFont
    let failureMessage: UIFont
    let lookbackSmall: UIFont

    nonisolated func headingGroup(level: Int) -> ChatFontGroup {
        if level <= 1 { return heading1 }
        if level == 2 { return heading2 }
        if level == 3 { return heading3 }
        return heading4
    }

    nonisolated static func italicized(_ font: UIFont, size: CGFloat) -> UIFont {
        if let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            return UIFont(descriptor: slanted, size: size)
        }
        return font
    }

    nonisolated static func tabularDigits(_ font: UIFont, size: CGFloat) -> UIFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
                ],
            ],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    @MainActor
    private static func alignedCodeFonts(size: CGFloat, preference: Pref.Code, italic: Bool) -> AlignedPair {
        let key = AlignedPairKey(sizeKey: Int((size * 2).rounded()), codePref: preference, italic: italic)
        if let hit = alignedPairCache.get(key) { return hit }

        let baseMono = Ink.uiMono(size, preference: preference)
        let targetMono = italic ? italicized(baseMono, size: size) : baseMono
        let pair: AlignedPair
        if preference == .maple && Ink.has("MapleMono-Regular") && Ink.has("ClioMonoCN-Regular") {
            pair = AlignedPair(narrow: targetMono, wide: targetMono)
        } else {
            let wideBase = UIFont.systemFont(ofSize: size)
            let targetWide = italic ? italicized(wideBase, size: size) : wideBase
            let native = targetMono as CTFont
            var zero: UniChar = 48
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(native, &zero, &glyph, 1) {
                let advance = CTFontGetAdvancesForGlyphs(native, .horizontal, &glyph, nil, 1)
                if advance > 0 {
                    let matrix = CGAffineTransform(scaleX: size * 0.5 / advance, y: 1)
                    let scaledDescriptor = targetMono.fontDescriptor.withMatrix(matrix)
                    let halfFont = UIFont(descriptor: scaledDescriptor, size: size)
                    pair = AlignedPair(narrow: halfFont, wide: targetWide)
                } else {
                    pair = AlignedPair(narrow: targetMono, wide: targetWide)
                }
            } else {
                pair = AlignedPair(narrow: targetMono, wide: targetWide)
            }
        }
        alignedPairCache.set(pair, for: key)
        return pair
    }

    @MainActor
    static func resolve(face: Pref.Face, code: Pref.Code, metrics: ChatResolvedMetrics) -> ChatResolvedFonts {
        let baseMono = Ink.uiMono(metrics.codeSize, preference: code)
        let plainItalic = italicized(baseMono, size: metrics.codeSize)
        let alignedRegular = alignedCodeFonts(size: metrics.codeSize, preference: code, italic: false)
        let alignedItalic = alignedCodeFonts(size: metrics.codeSize, preference: code, italic: true)
        let smallFont = UIFont.systemFont(ofSize: metrics.sizeSmall)
        let subFont = UIFont.systemFont(ofSize: metrics.sizeSub)
        let hWeight = metrics.headingWeight.uiWeight
        let bodyPt = metrics.bodyBox.effectivePointSize
        let tableGroup = ChatFontGroup.resolve(size: metrics.tableBox.effectivePointSize, face: face, code: code)
        return ChatResolvedFonts(
            reading: ChatFontGroup.resolve(size: bodyPt, face: face, code: code),
            heading1: ChatFontGroup.resolve(size: metrics.h1Box.effectivePointSize, face: face, code: code, regularWeight: hWeight, boldWeight: hWeight),
            heading2: ChatFontGroup.resolve(size: metrics.h2Box.effectivePointSize, face: face, code: code, regularWeight: hWeight, boldWeight: hWeight),
            heading3: ChatFontGroup.resolve(size: metrics.h3Box.effectivePointSize, face: face, code: code, regularWeight: hWeight, boldWeight: hWeight),
            heading4: ChatFontGroup.resolve(size: metrics.h4Box.effectivePointSize, face: face, code: code, regularWeight: .medium, boldWeight: .medium),
            quote: ChatFontGroup.resolve(size: metrics.quoteBox.effectivePointSize, face: face, code: code),
            table: tableGroup,
            tableNumericRegular: tabularDigits(tableGroup.regular, size: metrics.tableBox.effectivePointSize),
            tableNumericBold: tabularDigits(tableGroup.bold, size: metrics.tableBox.effectivePointSize),
            userBody: Ink.uiFace(metrics.userBox.effectivePointSize, weight: .regular, face: face),
            disclosureSmall: smallFont,
            ruleMicro: UIFont.systemFont(ofSize: metrics.sizeMicro),
            listNumberMarker: tabularDigits(Ink.uiFace(bodyPt * 0.92, weight: .regular, face: face), size: bodyPt * 0.92),
            listBulletDepth0: Ink.uiFace(bodyPt * 0.95, face: face),
            listBulletDepthNested: Ink.uiFace(bodyPt * 0.78, face: face),
            codePlainRegular: baseMono,
            codePlainItalic: plainItalic,
            codeAlignedRegularNarrow: alignedRegular.narrow,
            codeAlignedRegularWide: alignedRegular.wide,
            codeAlignedItalicNarrow: alignedItalic.narrow,
            codeAlignedItalicWide: alignedItalic.wide,
            noteAdviceTitle: UIFont.systemFont(ofSize: metrics.sizeSub, weight: .semibold),
            noteAdviceDetail: subFont,
            notePlain: smallFont,
            queuedMessage: UIFont.systemFont(ofSize: metrics.sizeBody, weight: .medium),
            failureMessage: subFont,
            lookbackSmall: smallFont
        )
    }
}

/// Snapshot of reading typography, palette, Dynamic Type, and scale for the UIKit chat list.
struct ChatListStyle: Equatable, Sendable {
    let face: Pref.Face
    let code: Pref.Code
    let size: Double
    let lineHeight: Double
    let paragraphGapValue: Double
    let headingWeight: Pref.HeadingWeight
    let clreqSqueeze: Bool
    let readingWidth: Double
    let uiDensity: Pref.UIDensity
    let fade: Bool
    let reduceMotion: Bool
    let uiScale: Double
    let themeKey: String
    let white: Bool
    let oled: Bool
    let bubble: String
    let fontGeneration: Int
    let isDark: Bool
    let contentSizeCategory: String
    let isPlainTone: Bool
    let styleKey: String
    let layoutStyleKey: String
    let colors: ChatResolvedColors
    let metrics: ChatResolvedMetrics
    let fonts: ChatResolvedFonts

    init(
        face: Pref.Face,
        code: Pref.Code,
        size: Double,
        lineHeight: Double,
        paragraphGapValue: Double,
        headingWeight: Pref.HeadingWeight,
        clreqSqueeze: Bool,
        readingWidth: Double,
        uiDensity: Pref.UIDensity,
        fade: Bool,
        reduceMotion: Bool,
        uiScale: Double,
        themeKey: String,
        white: Bool,
        oled: Bool,
        bubble: String,
        fontGeneration: Int,
        isDark: Bool,
        contentSizeCategory: String,
        isPlainTone: Bool,
        colors: ChatResolvedColors,
        metrics: ChatResolvedMetrics,
        fonts: ChatResolvedFonts
    ) {
        self.face = face
        self.code = code
        self.size = size
        self.lineHeight = lineHeight
        self.paragraphGapValue = paragraphGapValue
        self.headingWeight = headingWeight
        self.clreqSqueeze = clreqSqueeze
        self.readingWidth = readingWidth
        self.uiDensity = uiDensity
        self.fade = fade
        self.reduceMotion = reduceMotion
        self.uiScale = uiScale
        self.themeKey = themeKey
        self.white = white
        self.oled = oled
        self.bubble = bubble
        self.fontGeneration = fontGeneration
        self.isDark = isDark
        self.contentSizeCategory = contentSizeCategory
        self.isPlainTone = isPlainTone
        self.layoutStyleKey = "\(face.rawValue)|\(code.rawValue)|\(size)|\(lineHeight)|\(paragraphGapValue)|\(headingWeight.rawValue)|\(clreqSqueeze)|\(readingWidth)|\(uiDensity.rawValue)|\(fade)|\(reduceMotion)|\(uiScale)|\(fontGeneration)|\(contentSizeCategory)"
        self.styleKey = "\(self.layoutStyleKey)|\(themeKey)|\(white)|\(oled)|\(bubble)|\(isDark)|\(isPlainTone ? 1 : 0)"
        self.colors = colors
        self.metrics = metrics
        self.fonts = fonts
    }

    var scale: CGFloat { metrics.scale }
    var readingSize: CGFloat { metrics.readingSize }
    var codeSize: CGFloat { metrics.codeSize }
    var inlineCodeSize: CGFloat { metrics.inlineCodeSize }
    var tableCellSize: CGFloat { metrics.tableCellSize }
    var leading: CGFloat { metrics.leading }
    var paragraphGap: CGFloat { metrics.paragraphGap }
    var listSpacing: CGFloat { metrics.listSpacing }
    var headingBottom: CGFloat { metrics.headingBottom }
    var codeLineSpacing: CGFloat { metrics.codeLineSpacing }
    var codeHeaderHeight: CGFloat { metrics.codeHeaderHeight }
    var codeFoldButtonHeight: CGFloat { metrics.codeFoldButtonHeight }
    var inlineCodeCorner: CGFloat { metrics.inlineCodeCorner }

    private static let lightTraitCollection = UITraitCollection(userInterfaceStyle: .light)
    private static let darkTraitCollection = UITraitCollection(userInterfaceStyle: .dark)

    private var resolvedTraitCollection: UITraitCollection {
        isDark ? Self.darkTraitCollection : Self.lightTraitCollection
    }

    @MainActor
    func resolveColor(_ color: Color, alpha: CGFloat = 1) -> UIColor {
        let base = UIColor(color).resolvedColor(with: resolvedTraitCollection)
        return alpha < 1 ? base.withAlphaComponent(alpha) : base
    }

    @MainActor
    static func current(traits: UITraitCollection, reduceMotion: Bool = false) -> ChatListStyle {
        let theme = Theme.shared
        let face = theme.face
        let code = theme.code
        let size = theme.size
        let lineHeight = theme.lineHeight
        let paragraphGapValue = theme.paragraphGap
        let headingWeight = theme.headingWeight
        let clreqSqueeze = theme.clreqSqueeze
        let readingWidth = theme.readingWidth
        let uiDensity = theme.uiDensity
        let fade = theme.fade
        let uiScale = UIScale.shared.value
        let isDark = traits.userInterfaceStyle == .dark
        let resolvedTraits = isDark ? darkTraitCollection : lightTraitCollection
        let colors = ChatResolvedColors.resolve(traits: resolvedTraits)
        let metrics = ChatResolvedMetrics.resolve(
            size: size,
            lineHeight: lineHeight,
            paragraphGap: paragraphGapValue,
            headingWeight: headingWeight,
            clreqSqueeze: clreqSqueeze,
            readingWidth: readingWidth,
            face: face,
            code: code,
            uiScale: uiScale
        )
        let fonts = ChatResolvedFonts.resolve(face: face, code: code, metrics: metrics)
        return ChatListStyle(
            face: face,
            code: code,
            size: size,
            lineHeight: lineHeight,
            paragraphGapValue: paragraphGapValue,
            headingWeight: headingWeight,
            clreqSqueeze: clreqSqueeze,
            readingWidth: readingWidth,
            uiDensity: uiDensity,
            fade: fade,
            reduceMotion: reduceMotion,
            uiScale: uiScale,
            themeKey: theme.key,
            white: theme.white,
            oled: theme.oled,
            bubble: theme.bubble,
            fontGeneration: FontShelf.shared.generation,
            isDark: isDark,
            contentSizeCategory: traits.preferredContentSizeCategory.rawValue,
            isPlainTone: theme.plain,
            colors: colors,
            metrics: metrics,
            fonts: fonts
        )
    }

    func headingSize(level: Int) -> CGFloat {
        metrics.headingSize(level: level)
    }

    func headingTop(level: Int) -> CGFloat {
        metrics.headingTop(level: level)
    }

    func headingBottom(level: Int) -> CGFloat {
        metrics.headingBottom(level: level)
    }
}

/// Pure `Sendable` snapshot of dynamic per-block height overrides for a single row owner.
struct BlockOverrideSnapshot: Equatable, Sendable {
    let ownerID: String
    let version: UInt64
    let heights: [String: CGFloat]

    static func empty(ownerID: String = "") -> BlockOverrideSnapshot {
        BlockOverrideSnapshot(ownerID: ownerID, version: 1, heights: [:])
    }
}

/// Pure `Sendable` measurement input extracted from `ChatListRowItem` for off-main-thread user row layout.
struct UserMeasureInput: Sendable {
    let id: String
    let text: String
    let photoCount: Int
    let isFirst: Bool
    let opens: Bool
    let faces: Bool
    let hasTimeGap: Bool
    let collectionWidth: CGFloat
    let style: ChatListStyle

    @MainActor
    init(row: ChatListRowItem, collectionWidth: CGFloat, style: ChatListStyle) {
        self.id = row.line.id
        self.text = row.line.text
        self.photoCount = row.line.refs.count
        self.isFirst = row.isFirst
        self.opens = row.opens
        self.faces = row.faces
        self.hasTimeGap = row.faces && row.opens && row.timeGap != nil
        self.collectionWidth = collectionWidth
        self.style = style
    }
}

/// Pure `Sendable` measurement input extracted from `ChatListRowItem` + UI toggle state for off-main-thread assistant layout.
struct AssistantMeasureInput: Sendable {
    let id: String
    let text: String
    let reasoning: String?
    let pulse: String?
    let lookbackNote: String?
    let lookbackRest: String
    let opens: Bool
    let faces: Bool
    let isRoom: Bool
    let showThinking: Bool
    let hasTimeGap: Bool
    let hasSources: Bool
    let hasContinue: Bool
    let hasFooter: Bool
    let isFresh: Bool
    let freshShown: Int?
    let expandedThinking: Bool
    let expandedPulse: Bool
    let expandedLookback: Bool
    let unfoldedSlices: Set<Int>
    let collectionWidth: CGFloat
    let style: ChatListStyle
    let overrides: BlockOverrideSnapshot

    @MainActor
    init(
        row: ChatListRowItem,
        collectionWidth: CGFloat,
        style: ChatListStyle,
        expandedThinking: Bool,
        expandedPulse: Bool,
        expandedLookback: Bool,
        unfoldedSlices: Set<Int>,
        overrides: BlockOverrideSnapshot
    ) {
        let isFresh = row.isFreshWriting
        let shown = row.freshShown ?? row.line.text.count
        self.id = row.line.id
        self.text = row.line.text
        self.reasoning = row.line.reasoning
        self.pulse = row.line.pulse
        self.lookbackNote = row.lookbackNote
        self.lookbackRest = isFresh ? String(row.line.text.prefix(shown)) : row.lookbackRest
        self.opens = row.opens
        self.faces = row.faces
        self.isRoom = row.isRoom
        self.showThinking = row.showThinking
        self.hasTimeGap = row.faces && row.opens && row.timeGap != nil
        self.hasSources = !isFresh && (row.lineMeta?.urls.isEmpty == false)
        self.hasContinue = !isFresh && row.hitStepLimit
        self.hasFooter = !isFresh && (row.isLatestBot ? !row.working : row.endsTurn)
        self.isFresh = isFresh
        self.freshShown = isFresh ? shown : nil
        self.expandedThinking = expandedThinking
        self.expandedPulse = expandedPulse
        self.expandedLookback = expandedLookback
        self.unfoldedSlices = unfoldedSlices
        self.collectionWidth = collectionWidth
        self.style = style
        self.overrides = overrides
    }
}

/// Stable diffable identifier for every row and live accessory in the UIKit chat list.
enum ChatListItemID: Hashable, Sendable {
    case emptyStatus
    case earlierButton
    case line(String)
    case liveFolding
    case livePulse
    case liveThinking
    case liveProse(Int)
    case liveToolTail
    case liveFailure
    case queued(UUID)
    case bottomSpacer

    var rowID: String? {
        switch self {
        case .line(let id): return id
        case .liveFolding: return "folding"
        case .livePulse: return "pulse"
        case .liveThinking: return "thinking"
        case .liveProse: return "streaming"
        case .liveToolTail: return "live"
        default: return nil
        }
    }
}

/// Settled row payload precomputed once per snapshot from `ChatPage.SourcesMemo`.
struct ChatListRowItem: Equatable {
    let line: ChatLine
    let opens: Bool
    let lit: Bool
    let isFirst: Bool
    let isFreshWriting: Bool
    var freshShown: Int?
    let isLatestBot: Bool
    let isLatestNote: Bool
    let isLastLine: Bool
    let endsTurn: Bool
    let timeGap: String?
    let isEditing: Bool
    let faces: Bool
    let isRoom: Bool
    let historyInView: Bool
    let speakerBot: BotInfo?
    let defaultBotName: String
    let lineMeta: ChatPage.SourcesMemo.LineMeta?
    let lookbackNote: String?
    let lookbackRest: String
    let showThinking: Bool
    let showStats: Bool
    let hitStepLimit: Bool
    let working: Bool
    let speakingText: String?

    var speakerTitle: String {
        speakerBot?.name ?? line.speakerName ?? defaultBotName
    }

    var isSpeakingThisLine: Bool {
        speakingText == line.text
    }
}

/// Selection snapshot captured across a live-streaming to settled-row handoff.
struct ChatProseSelectionSnapshot {
    let richTextIndex: Int
    let range: NSRange
    let substring: String
}

/// Full immutable render snapshot fed into `ChatListViewController`.
struct ChatListState {
    let chatKey: String
    let loaded: Bool
    let canLoadEarlier: Bool
    let isLoadingEarlier: Bool
    let historyInView: Bool
    let isRoom: Bool
    let defaultBot: BotInfo
    let teamBots: [BotInfo]
    let working: Bool
    let sendingBlocked: Bool
    let faces: Bool
    let rows: [ChatListRowItem]
    let isCompressing: Bool
    let streamPulse: String
    let streamPulseSpeaker: BotInfo?
    let streamReasoning: String
    let streamText: String
    let streamGeneration: Int
    let hasStreaming: Bool
    let fresh: ChatModel.Fresh?
    let showToolTail: Bool
    let failureCardError: String?
    let queuedItems: [TeamModel.Queued]
    let emptyPetState: String
    let starters: [(String, String, String)]
    let reach: String
    let headerHeight: CGFloat
    let reduceMotion: Bool

    func isEquivalent(to other: ChatListState) -> Bool {
        guard chatKey == other.chatKey,
              loaded == other.loaded,
              canLoadEarlier == other.canLoadEarlier,
              isLoadingEarlier == other.isLoadingEarlier,
              historyInView == other.historyInView,
              isRoom == other.isRoom,
              working == other.working,
              sendingBlocked == other.sendingBlocked,
              faces == other.faces,
              isCompressing == other.isCompressing,
              hasStreaming == other.hasStreaming,
              showToolTail == other.showToolTail,
              reduceMotion == other.reduceMotion,
              streamGeneration == other.streamGeneration,
              headerHeight == other.headerHeight else {
            return false
        }
        guard streamText == other.streamText,
              streamReasoning == other.streamReasoning,
              streamPulse == other.streamPulse,
              reach == other.reach,
              emptyPetState == other.emptyPetState,
              failureCardError == other.failureCardError,
              fresh == other.fresh else {
            return false
        }
        guard defaultBot == other.defaultBot,
              streamPulseSpeaker == other.streamPulseSpeaker,
              teamBots == other.teamBots,
              queuedItems == other.queuedItems else {
            return false
        }
        guard starters.count == other.starters.count else { return false }
        for (lhs, rhs) in zip(starters, other.starters) {
            if lhs.0 != rhs.0 || lhs.1 != rhs.1 || lhs.2 != rhs.2 {
                return false
            }
        }
        guard rows.count == other.rows.count else { return false }
        let sameRowBuffer = rows.withUnsafeBufferPointer { lhs in
            other.rows.withUnsafeBufferPointer { rhs in
                lhs.baseAddress == rhs.baseAddress
            }
        }
        if sameRowBuffer { return true }
        return rows == other.rows
    }
}

/// Snapshot of a tapped UIKit photo thumbnail for SwiftUI Hero zoom transition.
struct ChatPhotoHeroTarget: Equatable {
    let id: String
    let globalRect: CGRect
    let image: UIImage?

    static func == (lhs: ChatPhotoHeroTarget, rhs: ChatPhotoHeroTarget) -> Bool {
        lhs.id == rhs.id && lhs.globalRect == rhs.globalRect && lhs.image === rhs.image
    }
}

/// Callbacks and dependencies bridging UIKit cells & scroll events back to `ChatPage`.
@MainActor
final class ChatListActions {
    let chat: ChatModel
    let team: TeamModel
    let bridge: ChatRowBridge
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let petPerch: PetPerch

    var onLoadEarlier: () -> Void = {}
    var onQuoteExcerpt: (String) -> Void = { _ in }
    var onSpeakExcerpt: (String) -> Void = { _ in }
    var onSaveNoteExcerpt: (String, String) -> Void = { _, _ in }
    var onSelectionChanged: (UUID, Bool) -> Void = { _, _ in }
    var onFollowingChanged: (Bool) -> Void = { _ in }
    var onTouchScrollingChanged: (Bool, Bool) -> Void = { _, _ in }
    var onScrollingChanged: (Bool) -> Void = { _ in }
    var onFarFromEndChanged: (Bool) -> Void = { _ in }
    var onNeedsEndCorrectionChanged: (Bool) -> Void = { _ in }
    var onVisibleIDsChanged: ([String]) -> Void = { _ in }
    var onActiveTurnChanged: (String?) -> Void = { _ in }
    var onScrollPhaseChanged: (String) -> Void = { _ in }
    var onScrollDelta: (CGFloat, CGFloat, CGFloat, CGFloat, Bool, Bool) -> Void = { _, _, _, _, _, _ in }
    var onChromeDragEnded: () -> Void = {}
    var canRestoreImmersiveChrome: () -> Bool = { false }
    var onImmersiveBackgroundTap: () -> Void = {}
    var onKeyboardVisibilityChanged: (Bool) -> Void = { _ in }
    var onProgrammaticScroll: () -> Void = {}
    var onDragStarted: () -> Void = {}
    var onScrollEnded: () -> Void = {}
    var onPickStarter: (String) -> Void = { _ in }
    var onPreparePhotoHero: (ChatPhotoHeroTarget) -> Void = { _ in }
    var onClearPhotoHero: (String) -> Void = { _ in }
    var currentPreparedHeroID: () -> String? = { nil }

    init(
        chat: ChatModel,
        team: TeamModel,
        bridge: ChatRowBridge,
        dictationSlot: ChatDictationSlot,
        idleMood: ChatIdleMood,
        petPerch: PetPerch
    ) {
        self.chat = chat
        self.team = team
        self.bridge = bridge
        self.dictationSlot = dictationSlot
        self.idleMood = idleMood
        self.petPerch = petPerch
    }
}

/// Scroll bridge allowing `ChatPage` navigation actions (find, outline, minimap, returnToLatest) to drive UIKit.
@MainActor
final class ChatListControllerProxy {
    weak var controller: ChatListViewController?

    var isNearBottom: Bool {
        controller?.isCurrentlyNearBottom ?? true
    }

    func scrollTo(id: String, anchor: UnitPoint, animated: Bool) {
        if id == ChatPage.end {
            controller?.scrollToBottomFromHost(animated: animated)
        } else {
            controller?.scrollToRow(id: id, anchor: anchor, animated: animated)
        }
    }

    func scrollToBottom(animated: Bool) {
        controller?.scrollToBottomFromHost(animated: animated)
    }

    func prewarmAround(id: String) {
        controller?.prewarmAroundRow(id: id)
    }
}

/// Shared layout constants matching Clio's SwiftUI chat rows.
@MainActor
enum ChatCellMetrics {
    @MainActor static var rowSpacing: CGFloat {
        switch Pref.uiDensity {
        case .compact: return Ink.Space.s
        case .standard: return Ink.Space.m
        case .comfortable: return Ink.Space.l
        }
    }
    static var sectionSpacing: CGFloat { Ink.Space.s }
    @MainActor static var userTurnTopPad: CGFloat {
        switch Pref.uiDensity {
        case .compact: return Ink.Space.m
        case .standard: return Ink.Space.l
        case .comfortable: return Ink.Space.xl
        }
    }
    static var speakerRowGap: CGFloat { Ink.Space.s }
    static var faceSize: CGFloat { ChatPage.face }
    static var compactSpeakerSize: CGFloat { 22 * UIScale.factor }
    static var timeGapHeight: CGFloat { 18 * UIScale.factor }
    static var timeGapBottomPad: CGFloat { Ink.Space.xs }
    static var photoSize: CGFloat { 72 * UIScale.factor }
    static var photoSpacing: CGFloat { Ink.Space.s }
    static var userBubblePadH: CGFloat { Ink.Space.l }
    static var userBubblePadV: CGFloat { 10 * UIScale.factor }
    @MainActor static var botBlockGap: CGFloat {
        switch Pref.uiDensity {
        case .compact: return Ink.Space.s
        case .standard: return Ink.Space.m
        case .comfortable: return Ink.Space.l
        }
    }
    static var disclosureHeaderHeight: CGFloat { 22 * UIScale.factor }
    static var disclosureGap: CGFloat { Ink.Space.s }
    static var sourcesPillHeight: CGFloat { 28 * UIScale.factor }
    static var continueButtonHeight: CGFloat { 34 * UIScale.factor }
    static var footerHeight: CGFloat { 28 * UIScale.factor }
    static var bottomSpacerHeight: CGFloat { Ink.Space.xxl + Ink.Space.l }
}

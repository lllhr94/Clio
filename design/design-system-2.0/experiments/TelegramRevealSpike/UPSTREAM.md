# Telegram Upstream Provenance & Adaptation Log (`TelegramRevealSpike`)

> **Disposable Experiment Notice**: This Swift Package lives exclusively under `design/design-system-2.0/experiments/TelegramRevealSpike/` for DS 2.0 v16 native engineering verification. It has zero build or runtime coupling to `App/` or `AgentKit/`, and does not modify Clio's `GPL-3.0` project license.

## 1. Upstream Repository & License Basis

- **Upstream Repository**: `https://github.com/TelegramMessenger/Telegram-iOS`
- **Pinned Commit SHA**: `24638bc69bd083981b178dd1e7f921eebbf7fc46`
- **Official License Statement**: `https://telegram.org/apps/` specifies **GNU General Public License v. 2 or later (`GPL-2.0-or-later`)** for Telegram for iOS; root `README.md` reiterates source publication compliance (`"Please remember to publish your code too in order to comply with the licences."`).
- **Clio License Compatibility**: `GPL-2.0-or-later` is explicitly compatible with Clio's `GPL-3.0` license (GPLv2 Section 9 / GPLv3 Section 7). Clio keeps `GPL-3.0`.
- **Branding & Dependency Guard**: Zero Telegram brand names, paper-plane assets, `AsyncDisplayKit`, `SwiftSignalKit`, `Display`, `TelegramCore`, `MTProto`, or unvetted Bazel sub-packages are imported.

## 2. File-by-File Source Mapping & Modification Record

| Local Spike File | Upstream Source (`24638bc`) | Copying / Adaptation Scope |
|---|---|---|
| `Sources/TelegramRevealUpstream/TextRevealController.swift` | `submodules/TelegramUI/Components/StreamingTextReveal/Sources/TextRevealController.swift` (L1–90, `BUILD` `deps = []`, `import Foundation` only) | **0-line diff (verbatim copy)** preserving `velocityTau = 0.12`, `gapEwmaAlpha = 0.4`, `initialGap = 0.5`, `stallFloor = 0.10`, `finalizeTime = 0.3`, `frameDtCap = 0.05`, `initialInputRate = 40.0`. |
| `Sources/ClioRevealSpike/RevealCostAndRects.swift` | `submodules/InstantPageUI/Sources/InstantPageV2RevealCost.swift` (L1–570) & `InstantPageV2Layout.swift` (`computeRevealCharacterRects`, L4640–4718) | Extracted pure `CoreText` ink-width `Points` cost model (`textInkWidth`, `itemWidthCost`, `charCountForWidthBudget`, `revealedMaxY`, `CTRunGetGlyphs` / `CTRunGetPositions` / `CTRunGetStringIndices` / `CTFontGetBoundingRectsForGlyphs`, ligature `CGRect.zero` handling), decoupled from `InstantPageV2LaidOutItem` / `AsyncDisplayKit` and guarded by Swift `Character` extended-grapheme-cluster snapping (CJK, Latin ligatures, Emoji ZWJ, skin tones, combining marks). |
| `Sources/ClioRevealSpike/RevealMaskRenderer.swift` | `submodules/InstantPageUI/Sources/InstantPageRenderer.swift` (`SnippetLayer` L1944–1965, `computeRevealedLines` L1526–1583, `updateRevealMask` L1585–1807) | Extracted pure `QuartzCore`/`CoreGraphics` `CALayer` mask line-merging (`pendingFullPrefix`) and `RevealSnippetLayer` (`contentsRect`, `0.20s` alpha/position/scale ease-in-out + `0.22s` blur metadata contract), replacing `SimpleLayer` & `ComponentTransition` with standard `CALayer` / `CABasicAnimation` + automatic downgrade (`Pref.fade`, Reduce Motion, Low Power Mode, thermal pressure, high `Points/s` burst). Also includes `#if canImport(UIKit)` `SpikeRevealTextView` for iOS Simulator validation. |
| `Sources/ClioRevealSpike/SafeLineBoxAndTypography.swift` | Clio DS 2.0 `specs/01-typography.md` (no Telegram code) | Clio `SafeLineBox` (`lineSpacing = 0`, `maximumLineHeight = 0`), `FontOpticalProfile`, `CTFontManagerCreateFontDescriptorsFromURL` loader for bundled `App/Fonts/*.ttf`, and non-doubling CJK–Latin `.kern` guard. |
| `Sources/ClioRevealSpike/StreamRevealAdapter.swift` | Upstream lifecycle concepts from `ChatMessageTextBubbleContentNode.swift` (L1014–1089) & `ChatMessageRichDataBubbleContentNode.swift` (L1615–1741) | Clean 4-stage Clio adapter (`received` / `parsed` / `laidOut` / `displayed`), `VirtualRevealScheduler` + idle-zero `CADisplayLinkRevealScheduler`, selection deferral, history scroll-anchor lock, Stop/Error prefix preservation, and Section 13 collaboration protocols for parallel audit seams. |

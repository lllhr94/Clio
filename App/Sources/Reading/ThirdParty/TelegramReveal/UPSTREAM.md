# Telegram Upstream Provenance & Adaptation Log (`TelegramReveal`)

## 1. Upstream Repository & License Basis

- **Upstream Repository**: `https://github.com/TelegramMessenger/Telegram-iOS`
- **Pinned Commit SHA**: `24638bc69bd083981b178dd1e7f921eebbf7fc46`
- **Official License Statement**: `https://telegram.org/apps/` specifies **GNU General Public License v. 2 or later (`GPL-2.0-or-later`)** for Telegram for iOS; the upstream root `README.md` reiterates source publication compliance (`"Please remember to publish your code too in order to comply with the licences."`).
- **Clio License Compatibility**: `GPL-2.0-or-later` is explicitly compatible with Clio's `GPL-3.0` license (GPLv2 Section 9 / GPLv3 Section 7). Clio keeps `GPL-3.0`.
- **Dependency & Branding Guard**: Zero Telegram brand names, paper-plane assets, `AsyncDisplayKit`, `SwiftSignalKit`, `Display`, `TelegramCore`, `MTProto`, or third-party transitive dependencies are imported.

## 2. File-by-File Source Mapping & Modification Record

| Local Clio File | Upstream Source (`24638bc`) | Scope & Changes |
|---|---|---|
| [`App/Sources/Reading/ThirdParty/TelegramReveal/TextRevealController.swift`](TextRevealController.swift) | `submodules/TelegramUI/Components/StreamingTextReveal/Sources/TextRevealController.swift` (`BUILD` `deps = []`, `import Foundation` only) | **0-line diff (verbatim copy)**, SHA256 `d666036aad737a263ecb5bd5e1084c36765c5969c084176378dbd80fcc96b4c6`. Preserves `velocityTau = 0.12`, `gapEwmaAlpha = 0.4`, `initialGap = 0.5`, `stallFloor = 0.10`, `finalizeTime = 0.3`, `frameDtCap = 0.05`, `initialInputRate = 40.0`, `durationMultiplier`, `observeUpdate`, `finalize`, and `tick`. |
| `App/Sources/Reading/ChatListUIKit/ChatRevealEngine.swift` *(Clio native UIKit/CoreText adapter)* | Concepts & algorithms adapted from `submodules/InstantPageUI/Sources/InstantPageV2RevealCost.swift` (L1–570), `InstantPageV2Layout.swift` (`computeRevealCharacterRects`, L4645–4718), and `InstantPageRenderer.swift` (`SnippetLayer`, `computeRevealedLines`, `updateRevealMask`) | Decoupled from `AsyncDisplayKit` / `InstantPage` / `ComponentFlow` onto Clio `CoreText` tiles (`ChatTextTileRenderer`), extended with Swift `Character` grapheme-cluster & ligature atomic snapping, shared idle-zero `CADisplayLink` lifecycle driver, background/Reduce-Motion/Low-Power/thermal/burst downgrade gates (`Pref.fade`), and seamless handoff across live-to-settled commit. |

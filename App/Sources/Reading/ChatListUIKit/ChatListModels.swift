import AgentKit
import Craft
import SwiftUI
import UIKit

/// Snapshot of reading typography, palette, Dynamic Type, and scale for the UIKit chat list.
@MainActor
struct ChatListStyle: Equatable {
    let face: Pref.Face
    let code: Pref.Code
    let size: Double
    let lineHeight: Double
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

    var scale: CGFloat { CGFloat(uiScale) }
    var readingSize: CGFloat { CGFloat(size) }
    var codeSize: CGFloat { max(CGFloat(12), CGFloat(size) - 3) }
    var inlineCodeSize: CGFloat { max(CGFloat(12), CGFloat(size) - 2) }
    var tableCellSize: CGFloat { max(CGFloat(12), CGFloat(size) - 2) }
    var leading: CGFloat { Ink.leading(size: size, lineHeight: lineHeight, face: face) }
    var paragraphGap: CGFloat { CGFloat(size) * 0.72 }
    var listSpacing: CGFloat { CGFloat(size) * 0.42 }
    var headingBottom: CGFloat { CGFloat(size) * 0.35 }
    var codeLineSpacing: CGFloat { max(1.5, codeSize * 0.13) }
    var codeHeaderHeight: CGFloat { 32 * scale }
    var codeFoldButtonHeight: CGFloat { 34 * scale }
    var inlineCodeCorner: CGFloat { 5 * scale }

    var styleKey: String {
        "\(face.rawValue)|\(code.rawValue)|\(size)|\(lineHeight)|\(fade)|\(reduceMotion)|\(uiScale)|\(themeKey)|\(white)|\(oled)|\(bubble)|\(fontGeneration)|\(isDark)|\(contentSizeCategory)"
    }

    static func current(traits: UITraitCollection, reduceMotion: Bool = false) -> ChatListStyle {
        let theme = Theme.shared
        return ChatListStyle(
            face: theme.face,
            code: theme.code,
            size: theme.size,
            lineHeight: theme.lineHeight,
            fade: theme.fade,
            reduceMotion: reduceMotion,
            uiScale: UIScale.shared.value,
            themeKey: theme.key,
            white: theme.white,
            oled: theme.oled,
            bubble: theme.bubble,
            fontGeneration: FontShelf.shared.generation,
            isDark: traits.userInterfaceStyle == .dark,
            contentSizeCategory: traits.preferredContentSizeCategory.rawValue
        )
    }

    func headingSize(level: Int) -> CGFloat {
        let base = readingSize
        if level <= 1 { return (base * 1.24).rounded() }
        if level == 2 { return (base * 1.13).rounded() }
        return (base * 1.05).rounded()
    }

    func headingTop(level: Int) -> CGFloat {
        let base = readingSize
        if level <= 1 { return base * 1.1 }
        if level == 2 { return base * 0.85 }
        return base * 0.55
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
    let freshShown: Int?
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
    var onScrollPhaseChanged: (String) -> Void = { _ in }
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
}

/// Shared layout constants matching Clio's SwiftUI chat rows.
@MainActor
enum ChatCellMetrics {
    static var rowSpacing: CGFloat { Ink.Space.m }
    static var sectionSpacing: CGFloat { Ink.Space.s }
    static var userTurnTopPad: CGFloat { Ink.Space.l }
    static var speakerRowGap: CGFloat { Ink.Space.s }
    static var faceSize: CGFloat { ChatPage.face }
    static var compactSpeakerSize: CGFloat { 22 * UIScale.factor }
    static var timeGapHeight: CGFloat { 18 * UIScale.factor }
    static var timeGapBottomPad: CGFloat { Ink.Space.xs }
    static var photoSize: CGFloat { 72 * UIScale.factor }
    static var photoSpacing: CGFloat { Ink.Space.s }
    static var userBubblePadH: CGFloat { Ink.Space.l }
    static var userBubblePadV: CGFloat { 10 * UIScale.factor }
    static var botBlockGap: CGFloat { Ink.Space.m }
    static var disclosureHeaderHeight: CGFloat { 22 * UIScale.factor }
    static var disclosureGap: CGFloat { Ink.Space.s }
    static var sourcesPillHeight: CGFloat { 28 * UIScale.factor }
    static var continueButtonHeight: CGFloat { 34 * UIScale.factor }
    static var footerHeight: CGFloat { 28 * UIScale.factor }
    static var bottomSpacerHeight: CGFloat { Ink.Space.xxl + Ink.Space.l }
}

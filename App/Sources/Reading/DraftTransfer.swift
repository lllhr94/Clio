import Craft
import CryptoKit
import Foundation
import SwiftUI

/// Moves a conversation's persisted draft (text, photos, files, and queuedIds) to another conversation
/// with explicit collision handling (`append` / `replace` / `cancel`) and revision-checked 5-second undo.
@MainActor
enum DraftTransfer {
    enum CollisionPolicy: Equatable, Sendable {
        case append
        case replace
        case cancel
    }

    struct Snapshot: Equatable, Sendable {
        var text: String
        var photos: [Data]
        var files: [String]
        var queuedIds: [UUID]

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty && files.isEmpty
        }

        /// Deterministic fingerprint of text + attachments + queued IDs so revision-checked undo
        /// detects ANY edit made to either conversation after the move.
        var fingerprint: String {
            var hasher = SHA256()
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0x1E]))
            for file in files {
                hasher.update(data: Data(file.utf8))
                hasher.update(data: Data([0x1F]))
            }
            hasher.update(data: Data([0x1D]))
            for id in queuedIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                hasher.update(data: Data(id.uuidString.utf8))
            }
            hasher.update(data: Data([0x1C]))
            for photo in photos {
                var count = UInt64(photo.count).littleEndian
                withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
                hasher.update(data: photo)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Receipt: Equatable, Sendable {
        var sourceChat: String
        var targetChat: String
        var previousSource: Snapshot
        var previousTarget: Snapshot
        var expectedSourceFingerprintAfter: String
        var expectedTargetFingerprintAfter: String
        var createdAt: Date
        var undoWindowSeconds: TimeInterval = 5.0

        func isWithinUndoWindow(now: Date = Date()) -> Bool {
            now.timeIntervalSince(createdAt) <= undoWindowSeconds
        }
    }

    enum TransferResult: Equatable, Sendable {
        case moved(Receipt)
        case needsCollisionChoice
        case emptySource
        case sameConversation
        case cancelled
        case failed
    }

    enum UndoResult: Equatable, Sendable {
        case restored
        case expired
        case conflicted
        case failed
    }

    static func loadSnapshot(for chat: String) async -> Snapshot {
        let textDraft = await DraftTextStore.loadAsync(for: chat)
        let attachments = await DraftAttachments.loadAsync(chat)
        var mergedIDs = textDraft.queuedIds
        for id in attachments.queuedIds where !mergedIDs.contains(id) {
            mergedIDs.append(id)
        }
        return Snapshot(
            text: textDraft.text,
            photos: attachments.photos,
            files: attachments.files,
            queuedIds: mergedIDs
        )
    }

    static func saveSnapshot(_ snapshot: Snapshot, for chat: String) async -> Bool {
        let textSaved = await DraftTextStore.saveResult(
            StoredTextDraft(text: snapshot.text, queuedIds: snapshot.queuedIds),
            for: chat
        )
        let attSaved = await DraftAttachments.saveResult(
            photos: snapshot.photos,
            files: snapshot.files,
            chat: chat,
            queuedIds: snapshot.queuedIds
        )
        return textSaved && attSaved
    }

    /// Moves draft text + attachments + queuedIds from `sourceChat` to `targetChat`.
    /// When `targetChat` already has a non-empty draft and `policy == nil`, returns `.needsCollisionChoice`.
    static func move(
        from sourceChat: String,
        to targetChat: String,
        policy: CollisionPolicy? = nil,
        now: Date = Date()
    ) async -> TransferResult {
        guard sourceChat != targetChat else { return .sameConversation }
        let source = await loadSnapshot(for: sourceChat)
        guard !source.isEmpty else { return .emptySource }
        let target = await loadSnapshot(for: targetChat)

        let nextTarget: Snapshot
        if !target.isEmpty {
            guard let policy else { return .needsCollisionChoice }
            switch policy {
            case .cancel:
                return .cancelled
            case .replace:
                nextTarget = source
            case .append:
                let combinedText: String
                if target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    combinedText = source.text
                } else if source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    combinedText = target.text
                } else {
                    combinedText = target.text + "\n\n" + source.text
                }
                var mergedFiles = target.files
                for file in source.files where !mergedFiles.contains(file) {
                    mergedFiles.append(file)
                }
                var mergedIDs = target.queuedIds
                for id in source.queuedIds where !mergedIDs.contains(id) {
                    mergedIDs.append(id)
                }
                nextTarget = Snapshot(
                    text: combinedText,
                    photos: target.photos + source.photos,
                    files: mergedFiles,
                    queuedIds: mergedIDs
                )
            }
        } else {
            nextTarget = source
        }

        let clearedSource = Snapshot(text: "", photos: [], files: [], queuedIds: [])
        guard await saveSnapshot(nextTarget, for: targetChat) else { return .failed }
        guard await saveSnapshot(clearedSource, for: sourceChat) else {
            // Roll back target on failure to clear source.
            _ = await saveSnapshot(target, for: targetChat)
            return .failed
        }

        return .moved(Receipt(
            sourceChat: sourceChat,
            targetChat: targetChat,
            previousSource: source,
            previousTarget: target,
            expectedSourceFingerprintAfter: clearedSource.fingerprint,
            expectedTargetFingerprintAfter: nextTarget.fingerprint,
            createdAt: now
        ))
    }

    /// Reverts a completed `DraftTransfer.move` ONLY within the 5-second undo window AND ONLY when
    /// NEITHER `sourceChat` NOR `targetChat` has been edited since the transfer (verified by content fingerprint).
    static func undo(_ receipt: Receipt, now: Date = Date()) async -> UndoResult {
        guard receipt.isWithinUndoWindow(now: now) else { return .expired }
        let currentSource = await loadSnapshot(for: receipt.sourceChat)
        let currentTarget = await loadSnapshot(for: receipt.targetChat)
        guard currentSource.fingerprint == receipt.expectedSourceFingerprintAfter,
              currentTarget.fingerprint == receipt.expectedTargetFingerprintAfter else {
            return .conflicted
        }
        guard await saveSnapshot(receipt.previousSource, for: receipt.sourceChat) else { return .failed }
        guard await saveSnapshot(receipt.previousTarget, for: receipt.targetChat) else { return .failed }
        return .restored
    }
}

/// Target conversation picker sheet for `Move to...` draft transfer.
struct DraftTransferPickerSheet: View {
    @ObservedObject var team: TeamModel
    let currentChatKey: String
    let onSelect: (_ targetKey: String, _ targetTitle: String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var targets: [(key: String, title: String, symbol: String)] {
        var rows: [(key: String, title: String, symbol: String)] = []
        for bot in team.bots {
            let key = TeamModel.key(bot: bot.id)
            if key != currentChatKey {
                rows.append((key: key, title: bot.name, symbol: "person"))
            }
        }
        for room in team.rooms {
            let key = TeamModel.key(room: room.id)
            if key != currentChatKey {
                rows.append((key: key, title: room.name, symbol: "person.2"))
            }
        }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if targets.isEmpty {
                        Text(L.t("draftTransfer.noOtherChats"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                            .paperCard()
                    } else {
                        ForEach(targets, id: \.key) { item in
                            Button {
                                Haptics.light()
                                dismiss()
                                onSelect(item.key, item.title)
                            } label: {
                                RowLabel(title: item.title, line: nil, end: .chevron) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: Ink.Size.body))
                                        .foregroundStyle(Ink.inkSoft)
                                        .frame(width: Kit.badge)
                                }
                            }
                            .buttonStyle(TapStyle())
                            if item.key != targets.last?.key {
                                Kit.divider
                            }
                        }
                        .paperCard()
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("draftTransfer.pickerTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
            }
        }
    }
}

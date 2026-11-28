import UIKit

/// The neighborhood-dependent layout inputs already resolved by the chat page. Raw
/// adjoining IDs are intentionally excluded: a same-group insertion alone changes no geometry.
struct NeighborDescriptor: Equatable, Sendable {
    let opens: Bool
    let isFirst: Bool
    let endsTurn: Bool
    let hasTimeGap: Bool

    init(opens: Bool, isFirst: Bool, endsTurn: Bool, hasTimeGap: Bool) {
        self.opens = opens
        self.isFirst = isFirst
        self.endsTurn = endsTurn
        self.hasTimeGap = hasTimeGap
    }

    init(row: ChatListRowItem) {
        self.init(opens: row.opens, isFirst: row.isFirst, endsTurn: row.endsTurn,
                  hasTimeGap: row.faces && row.opens && row.timeGap != nil)
    }
}

@MainActor
final class ChatTimelineDataSource {
    typealias CollectionSource = UICollectionViewDiffableDataSource<ChatListItemID, ChatListItemID>

    private(set) var collectionSource: CollectionSource?
    private(set) var items: [ChatListItemID] = []
    private(set) var itemIndexByID: [ChatListItemID: Int] = [:]
    private(set) var rowByID: [String: ChatListRowItem] = [:]
    private(set) var neighbors: [String: NeighborDescriptor] = [:]
    private(set) var turnUserIDBySection: [String?] = []
    private(set) var firstUserRowID: String?
    private(set) var lastUserRowID: String?

    func attach(to collection: UICollectionView, cellProvider: @escaping CollectionSource.CellProvider) {
        collectionSource = CollectionSource(collectionView: collection, cellProvider: cellProvider)
    }

    func replace(items: [ChatListItemID], rows: [ChatListRowItem]) {
        replace(items: items, rowMap: Dictionary(uniqueKeysWithValues: rows.map { ($0.line.id, $0) }))
    }

    func replace(items: [ChatListItemID], rowMap: [String: ChatListRowItem]) {
        self.items = items
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element, $0.offset) })
        rowByID = rowMap
        neighbors = rowMap.mapValues { NeighborDescriptor(row: $0) }
        rebuildTurnUserIndex()
    }

    func updateRows(_ rows: [String: ChatListRowItem]) {
        let userBoundariesChanged = rows.contains { id, row in
            (row.line.kind == .user) != (rowByID[id]?.line.kind == .user)
        } || rowByID.contains { id, row in row.line.kind == .user && rows[id] == nil }
        rowByID = rows
        neighbors = rows.mapValues { NeighborDescriptor(row: $0) }
        if userBoundariesChanged { rebuildTurnUserIndex() }
    }

    func hasUnchangedRow(_ id: String, previousRows: [String: ChatListRowItem],
                         previousNeighbors: [String: NeighborDescriptor]) -> Bool {
        guard let row = rowByID[id], let neighbor = neighbors[id] else { return false }
        return previousNeighbors[id] == neighbor && previousRows[id] == row
    }

    func applyStructure() {
        var snapshot = NSDiffableDataSourceSnapshot<ChatListItemID, ChatListItemID>()
        snapshot.appendSections(items)
        for id in items { snapshot.appendItems([id], toSection: id) }
        collectionSource?.apply(snapshot, animatingDifferences: false)
    }

    static func buildItemIDs(for state: ChatListState) -> [ChatListItemID] {
        var out: [ChatListItemID] = []
        if !state.loaded || (state.rows.isEmpty && !state.hasStreaming && state.streamPulse.isEmpty && state.streamReasoning.isEmpty) {
            out.append(.emptyStatus)
        }
        if state.canLoadEarlier {
            out.append(.earlierButton)
        }
        for row in state.rows {
            out.append(.line(row.line.id))
        }
        if !state.historyInView {
            if state.isCompressing { out.append(.liveFolding) }
            if !state.streamPulse.isEmpty { out.append(.livePulse) }
            if !state.streamReasoning.isEmpty && (state.working || state.hasStreaming) { out.append(.liveThinking) }
            if state.hasStreaming { out.append(.liveProse(state.streamGeneration)) }
            if state.showToolTail { out.append(.liveToolTail) }
            if state.failureCardError != nil { out.append(.liveFailure) }
            for q in state.queuedItems { out.append(.queued(q.id)) }
        }
        out.append(.bottomSpacer)
        return out
    }

    private func rebuildTurnUserIndex() {
        var firstUser: String?
        var lastUser: String?
        for item in items {
            if case .line(let id) = item, rowByID[id]?.line.kind == .user {
                if firstUser == nil { firstUser = id }
                lastUser = id
            }
        }
        firstUserRowID = firstUser
        lastUserRowID = lastUser

        turnUserIDBySection = []
        turnUserIDBySection.reserveCapacity(items.count)
        var currentUserID = firstUser
        for item in items {
            if case .line(let id) = item, rowByID[id]?.line.kind == .user {
                currentUserID = id
            }
            turnUserIDBySection.append(currentUserID)
        }
    }

}

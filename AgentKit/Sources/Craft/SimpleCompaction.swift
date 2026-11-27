import AgentKit
import Foundation

/// Shortens stale tool text locally while keeping the original records available for a single undo.
public enum SimpleCompaction {
    public struct Undo<Record: Equatable> {
        fileprivate struct Change {
            let index: Int
            let before: Record
            let after: Record
        }

        fileprivate let changes: [Change]
        public var isEmpty: Bool { changes.isEmpty }
        public var changedCount: Int { changes.count }

        /// Restores every changed entry together, provided those entries still match the compacted records.
        public func restore(in records: [Record]) -> [Record]? {
            guard changes.allSatisfy({ records.indices.contains($0.index) && records[$0.index] == $0.after }) else {
                return nil
            }
            var restored = records
            for change in changes { restored[change.index] = change.before }
            return restored
        }
    }

    public static func compact<Record: Equatable>(
        _ records: [Record],
        message: WritableKeyPath<Record, Message>,
        keepingRecentTurns: Int = 2,
        maxToolOutputCharacters: Int = 2_000
    ) -> (records: [Record], undo: Undo<Record>) {
        guard maxToolOutputCharacters > 0 else { return (records, Undo(changes: [])) }
        let messages = records.map { $0[keyPath: message] }
        let userIndices = messages.indices.filter { messages[$0].role == .user }
        guard let protectedStart = userIndices.suffix(max(1, keepingRecentTurns)).first else {
            return (records, Undo(changes: []))
        }

        var compacted = records
        var changes: [Undo<Record>.Change] = []
        let note = "\n［较早的工具输出已截短］"
        for unit in ProtocolAtomicUnit.group(messages) where unit.sourceRange.upperBound <= protectedStart {
            for (result, sourceIndex) in zip(unit.messages, unit.sourceIndices) {
                guard let index = sourceIndex, result.role == .tool, !result.isError,
                      result.detail == nil, result.images.isEmpty,
                      result.mediaReferences?.isEmpty != false,
                      result.toolName != "image_note",
                      !result.text.contains("[image_ref: "), !result.text.contains("［图片编号："),
                      result.text.count > maxToolOutputCharacters else { continue }
                let noteText = String(note.suffix(maxToolOutputCharacters))
                let prefix = result.text.prefix(maxToolOutputCharacters - noteText.count)
                compacted[index][keyPath: message].text = String(prefix) + noteText
                changes.append(.init(index: index, before: records[index], after: compacted[index]))
            }
        }
        return (compacted, Undo(changes: changes))
    }
}

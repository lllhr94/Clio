import Foundation

/// Merges cumulative speech-recognition updates into a user-editable composer draft.
/// If the user edits the draft mid-dictation (e.g. inserting punctuation or fixing a typo),
/// the previously recognized text is frozen so later cumulative recognition callbacks only
/// append newly spoken words instead of re-inserting the already-recognized prefix.
public struct DictationDraftMerger: Sendable, Equatable {
    private var base: String = ""
    private var expectedDraft: String = ""
    private var lastHeard: String = ""
    private var frozenHeard: String = ""

    public init() {}

    public mutating func start(initialDraft: String) {
        base = initialDraft
        expectedDraft = initialDraft
        lastHeard = ""
        frozenHeard = ""
    }

    public mutating func merge(currentDraft: String, heard: String) -> String {
        if currentDraft != expectedDraft {
            base = currentDraft
            frozenHeard = lastHeard
        }

        var tail = Self.suffix(of: heard, afterFrozen: frozenHeard, baseEndsWithPunctuation: Self.endsWithPunctuation(base))
        if !frozenHeard.isEmpty && tail.isEmpty {
            lastHeard = heard
            expectedDraft = base
            return base
        }

        if Self.needsSpace(between: base, and: tail) {
            tail = " " + tail
        }
        let updated = base + tail
        lastHeard = heard
        expectedDraft = updated
        return updated
    }

    private static func suffix(of heard: String, afterFrozen frozen: String, baseEndsWithPunctuation: Bool) -> String {
        guard !frozen.isEmpty else { return heard }
        var tail: Substring
        if heard.hasPrefix(frozen) {
            tail = heard.dropFirst(frozen.count)
        } else {
            let frozenCoreCount = frozen.reduce(0) { count, char in
                count + (isCoreCharacter(char) ? 1 : 0)
            }
            if frozenCoreCount == 0 {
                tail = heard[...]
            } else {
                var seen = 0
                var idx = heard.startIndex
                while idx < heard.endIndex && seen < frozenCoreCount {
                    if isCoreCharacter(heard[idx]) {
                        seen += 1
                    }
                    idx = heard.index(after: idx)
                }
                guard seen == frozenCoreCount else { return "" }
                tail = heard[idx...]
            }
        }

        if baseEndsWithPunctuation {
            while let first = tail.first, isPunctuation(first) {
                tail = tail.dropFirst()
            }
        }
        return String(tail)
    }

    private static func isCoreCharacter(_ char: Character) -> Bool {
        !isPunctuation(char) && !char.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    private static func isPunctuation(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    private static func endsWithPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return isPunctuation(last)
    }

    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return false }
        return isASCIIWord(l) && isASCIIWord(r)
    }

    private static func isASCIIWord(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}

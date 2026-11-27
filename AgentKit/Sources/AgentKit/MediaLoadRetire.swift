import Foundation

/// One tool image as seen from the current point in the conversation.
public struct MediaReference: Equatable, Sendable {
    public let ref: String
    public let note: String?
    public let sourceTool: String?
    public let turnIndex: Int
    public var expired: Bool

    public init(ref: String, note: String? = nil, sourceTool: String? = nil, turnIndex: Int, expired: Bool = false) {
        self.ref = ref
        self.note = note
        self.sourceTool = sourceTool
        self.turnIndex = turnIndex
        self.expired = expired
    }

    public var placeholder: String {
        let note = note?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "|", with: "｜") ?? ""
        return "[image_ref: \(ref) | note: \(note)]"
    }

    public var marker: String { expired ? MediaLoadRetire.expiredMarker(ref) : placeholder }
}

/// Reference and turn rules for tool images retained in a conversation transcript.
public enum MediaLoadRetire {
    public static let maxNoteLength = 500
    public static let saveFailure = "［图片保存失败，无法在后续对话中重读］"

    public static func reference(_ value: String) -> String? {
        guard value.utf8.count == 40, value.hasSuffix(".jpg"),
              let id = UUID(uuidString: String(value.dropLast(4))),
              id.uuidString + ".jpg" == value else { return nil }
        return value
    }

    public static func retainImage(turnAge: Int) -> Bool { (0...1).contains(turnAge) }

    public static func load(
        _ reference: MediaReference, read: (String) -> Data?
    ) -> (reference: MediaReference, image: ImagePart?) {
        var checked = reference
        let data = Self.reference(reference.ref).flatMap(read)
        checked.expired = data == nil
        return (checked, data.map(imagePart))
    }

    /// A result only advertises references after every image has been written.
    /// The host removes partial writes if a later image in the same result fails.
    public static func save(
        _ message: Message,
        write: (ImagePart) throws -> String,
        remove: (String) -> Void
    ) throws -> Message {
        guard message.role == .tool, !message.images.isEmpty, message.mediaReferences == nil else { return message }
        var references: [String] = []
        do {
            for image in message.images {
                references.append(try write(image))
            }
        } catch {
            for reference in references { remove(reference) }
            throw error
        }
        var kept = message
        kept.mediaReferences = references
        kept.text += availableMarker(references)
        return kept
    }

    public static func availableMarker(_ references: [String]) -> String {
        "\n［图片编号：\(references.joined(separator: "、"))］"
    }

    public static func expiredMarker(_ reference: String) -> String {
        "［截图已过期：\(reference)］"
    }

    public static func noteMarker(_ reference: String) -> String { "［图片笔记 \(reference)］" }

    /// Reads back a note produced by image_note, excluding untrusted text from other tools.
    public static func note(in message: Message) -> (reference: String, text: String)? {
        let prefix = "［图片笔记 "
        guard message.role == .tool, message.toolName == "image_note", !message.isError,
              message.text.hasPrefix(prefix), let end = message.text.firstIndex(of: "］"),
              let reference = reference(String(message.text.dropFirst(prefix.count).prefix(upTo: end))) else { return nil }
        let text = String(message.text.suffix(from: message.text.index(after: end)).prefix(maxNoteLength))
        guard !text.isEmpty else { return nil }
        return (reference, text)
    }

    /// Projects the image history without changing the transcript or the call/result pairing.
    public static func project(
        _ message: Message,
        references: [MediaReference],
        includeImages: Bool
    ) -> Message {
        guard message.role == .tool, !references.isEmpty else { return message }
        var projected = message
        let names = references.map(\.ref)
        let marker = availableMarker(names)
        if projected.text.hasSuffix(marker) { projected.text.removeLast(marker.count) }
        projected.mediaReferences = names
        if includeImages {
            projected.text += marker
        } else {
            projected.images = []
            for reference in references { projected.text += "\n" + reference.marker }
        }
        return projected
    }

    /// JPEG or PNG bytes already normalized by the image store.
    public static func imagePart(_ data: Data) -> ImagePart {
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return ImagePart(mediaType: data.starts(with: png) ? "image/png" : "image/jpeg", data: data)
    }
}

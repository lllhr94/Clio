import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: Outline

    /// 问答目录: each thing you said, with how the answer began.
    var outline: [OutlineSheet.Pair] {
        var pairs: [OutlineSheet.Pair] = []
        let lines = lookupRows
        for (index, line) in lines.enumerated() where line.kind == .user && !line.text.isEmpty {
            let answer = lines[(index + 1)...].prefix { $0.kind != .user }.first { $0.kind == .bot && !$0.text.isEmpty }?.text
            pairs.append(.init(id: line.id, question: line.text, answer: answer.map { String(Pulse.split($0).rest.prefix(80)) }, at: line.at))
        }
        return pairs
    }
}

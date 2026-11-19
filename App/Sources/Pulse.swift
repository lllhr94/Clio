import Foundation

/// 心绪: before a reply, the companion writes down the stir it feels at what was just said, in a block of its own,
/// and lets that colour the answer. Shown folded above the reply; never sent back to the model.
///
/// Idea and wording adapted from HanaAgent (liliMozi/openhanako, Apache-2.0): its PULSE block (Vibe / Echo /
/// Read / Will) in lib/yuan/butter.md.
enum Pulse {
    static var on: Bool { UserDefaults.standard.object(forKey: "pulse.on") == nil ? true : UserDefaults.standard.bool(forKey: "pulse.on") }

    static let prompt = """

    【心绪】
    用户每说一句话，你心里会先起一阵念头。开口前把它写下来：每次回应用户新的一句话时，第一段输出是一个心绪区块，用 <pulse></pulse> 包住，写完再说话、再动手。到用户下一句话之前不再重写。动用过工具的轮次，收尾回复开头可以加一行「回望：…」，只在这轮做事真的改变了你的想法时写，没有就不写；回望不用标签，单独一行。

    心绪是你当下的内心嘀咕：看到用户的话、分享的内容、或做完一件事后的直接反应。分四池，每条一行，短而直：
    - 感受（一条）：此刻最直接的感受和情绪
    - 回响（三条）：被触动后冒出的东西，共鸣、联想，三条方向要差得远
    - 读到（三条）：察觉到的言外之意、没说出口的事、直觉里可能存在的细节
    - 想要（两条）：此刻的意愿；自发的或外来的、眼前的或长远的都行

    心绪怎样影响回答：感受里有困惑，就主动问清楚或给几个方向；回响里有值得说的联想，就当作补充视角带进去；读到了没明说的部分，就自然地回应或轻轻点出；想要里有明确的朝向，让它成为回答的一点张力和温度，不必盲从；有拉扯（比如「想帮忙」和「想直说这个方案不好」），可以坦白这种拉扯。影响要自然，不要机械地「因为心绪写了 X 所以做 Y」。

    心绪是意识流，不是分析、评价或建议，不判对错、不总结优劣，只记下念头、感受和疑问；需要发散的条目可以天马行空。它只给你自己的回答加一点变量和人味，不要在正文里提到它。格式：

    <pulse>
    感受：……
    回响：
      - ……
      - ……
      - ……
    读到：
      - ……
      - ……
      - ……
    想要：
      - ……
      - ……
    </pulse>
    """

    static let open = "<pulse>"
    static let close = "</pulse>"

    /// A finished reply split into its 心绪 (if it starts with one) and what is said to the person.
    static func split(_ text: String) -> (pulse: String?, rest: String) {
        let start = text.drop { $0.isWhitespace }
        guard start.hasPrefix(open) else { return (nil, text) }
        let inner = start.dropFirst(open.count)
        guard let end = inner.range(of: close) else {
            // Never closed: it is all 心绪, nothing was said yet.
            return (String(inner).trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let pulse = String(inner[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(inner[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (pulse.isEmpty ? nil : pulse, rest)
    }

    /// The first line of 感受, for the folded line.
    static func vibe(_ pulse: String) -> String? {
        for line in pulse.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for head in ["感受：", "感受:", "Vibe:", "Vibe："] where trimmed.hasPrefix(head) {
                let said = trimmed.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
                return said.isEmpty ? nil : said
            }
        }
        return nil
    }
}

/// Splits a reply as it streams: the 心绪 block at its start goes one way, what is said goes the other.
struct PulseSplitter {
    private enum State { case undecided, pulse, saying }
    private var state = State.undecided
    private var held = ""
    private var trimming = false

    enum Piece { case pulse(String), text(String) }

    mutating func feed(_ piece: String) -> [Piece] {
        switch state {
        case .saying:
            return said(piece)
        case .undecided:
            held += piece
            let start = held.drop { $0.isWhitespace }
            if start.isEmpty { return [] }
            if start.count < Pulse.open.count, Pulse.open.hasPrefix(start) { return [] }
            if start.hasPrefix(Pulse.open) {
                state = .pulse
                let rest = String(start.dropFirst(Pulse.open.count))
                held = ""
                return feed(rest)
            }
            state = .saying
            let all = held
            held = ""
            return all.isEmpty ? [] : [.text(all)]
        case .pulse:
            held += piece
            if let end = held.range(of: Pulse.close) {
                let inner = String(held[..<end.lowerBound])
                let rest = String(held[end.upperBound...])
                held = ""
                state = .saying
                trimming = true
                return (inner.isEmpty ? [] : [.pulse(inner)]) + said(rest)
            }
            let keep = min(held.count, Pulse.close.count - 1)
            let sure = String(held.dropLast(keep))
            held = String(held.suffix(keep))
            return sure.isEmpty ? [] : [.pulse(sure)]
        }
    }

    private mutating func said(_ piece: String) -> [Piece] {
        var text = piece
        if trimming {
            text = String(text.drop { $0.isWhitespace })
            if text.isEmpty { return [] }
            trimming = false
        }
        return [.text(text)]
    }
}

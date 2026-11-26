import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// The line under the conversation while the companion works: what it is doing, and for how long.
/// Above the composer while the companion works, after DSH Go: what it is doing, how many tools so far, how long.
/// A tap goes to the bottom of the conversation.
struct WorkingBar: View {
    let words: String
    let icon: String
    let tools: Int
    let since: Date
    /// Everything set to 放手: said on the bar, so it is never forgotten.
    var free = false
    let tap: () -> Void

    /// A word that grows with the work. The same few minutes always get the same word, so it does not flicker.
    private func mood(at now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        let hour = Calendar.current.component(.hour, from: now)
        let pools: [String]
        switch (tools, minutes, hour) {
        case (_, _, 0..<5): pools = ["夜深了，还在做", "陪你熬一会儿", "轻手轻脚地做"]
        case (0, 1..., _): pools = ["想得有点久", "在琢磨", "这题不简单"]
        case (0, _, _): return ""
        case (1...2, _, _): pools = ["上手了", "开个头"]
        case (3...6, _, _): pools = ["手感来了", "顺着往下做"]
        case (7...14, _, _): pools = ["越做越顺", "快理清了"]
        default: pools = ["大活，慢慢来", "一步步啃"]
        }
        // A new word only every two minutes or with the next stage.
        let slot = minutes / 2 + tools / 3
        return pools[slot % pools.count]
    }

    var body: some View {
        let statusKey = "\(icon)|\(words)"
        Button(action: tap) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .symbolEffect(.bounce, value: statusKey)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                Text(Words.t(words))
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: since, by: 30)) { context in
                    let word = mood(at: context.date)
                    let parts = [tools > 0 ? "工具 ×\(tools)" : "", word].filter { !$0.isEmpty }
                    if !parts.isEmpty {
                        Text(parts.joined(separator: "，"))
                            .font(.system(size: Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(-1)
                if free {
                    Text("放手")
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.warn)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Ink.warn.opacity(0.14), in: .capsule)
                        .fixedSize()
                }
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(Clock.running(seconds))
                        .font(.system(size: Ink.Size.small).monospacedDigit())
                        .foregroundStyle(Ink.inkSoft)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .frame(height: 40)
            .frame(maxWidth: 260 * UIScale.factor)
            .glassFace(in: Capsule())
            .animation(Ink.Motion.quick, value: words)
            .animation(Ink.Motion.quick, value: icon)
            .animation(Ink.Motion.quick, value: tools)
        }
        .buttonStyle(PressStyle(haptic: false))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityHint("回到对话最底下")
    }
}

/// Three dots that rise in turn.
struct Dots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Ink.inkSoft)
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -2.5 * max(0, sin((time * 5) - Double(index) * 0.8)))
                }
            }
            .padding(.leading, 2)
        }
        .frame(height: 10)
    }
}

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
    // MARK: Composer

    /// 你不在时: the other conversations that finished, failed or are waiting for you, one line each. Costs nothing.
    var awayCard: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text("你不在时").font(Ink.serif(14, bold: true)).foregroundStyle(Ink.inkSoft)
                Spacer()
                Button {
                    withAnimation(Ink.Motion.settle) { away = [] }
                } label: {
                    Image(systemName: "xmark").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint).frame(width: 28, height: 28)
                }
                .buttonStyle(TapStyle(grow: 8))
                .accessibilityLabel("知道了")
            }
            ForEach(away) { item in
                Button {
                    Haptics.tick(0.6)
                    withAnimation(Ink.Motion.settle) { away = [] }
                    NotificationCenter.default.post(name: .clioOpenChat, object: item.chat)
                } label: {
                    HStack(spacing: Ink.Space.s) {
                        Image(systemName: Self.awayIcon(item.kind)).foregroundStyle(item.kind == .failed ? Ink.stop : (item.kind == .waiting ? Ink.warn : Ink.accent)).frame(width: 18)
                        Text("\(team.chatName(item.chat))：\(Self.awayWords(item.kind))").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, Ink.Space.m)
        .padding(.vertical, Ink.Space.s)
        .glassBacking(in: RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    static func awayIcon(_ kind: Happening.Kind) -> String {
        switch kind {
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .waiting: "seal"
        }
    }

    static func awayWords(_ kind: Happening.Kind) -> String {
        switch kind {
        case .done: "那边的活做完了，回复在等你看"
        case .failed: "那边出了点问题"
        case .waiting: "在等你批准"
        }
    }
}

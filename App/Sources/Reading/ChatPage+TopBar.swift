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
    // MARK: Top bar

    var header: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            if largeText {
                HStack(alignment: .top, spacing: Ink.Space.s) {
                    headerBack
                    headerIdentity
                    Spacer(minLength: 0)
                    headerControls
                }
                modelMenu(compact: false)
                    .glassBacking(in: Capsule())
            } else {
                HStack(alignment: .center, spacing: Ink.Space.s) {
                    headerBack
                    headerIdentity
                    Spacer(minLength: Ink.Space.xs)
                    headerControls
                        .layoutPriority(1)
                }
            }
        }
        .onChange(of: offeredThinking, initial: true) { _, offered in
            resetUnavailableThinking(in: offered)
        }
        .padding(.horizontal, Ink.Bar.edge)
        .padding(.top, Ink.Space.xs)
        .padding(.bottom, Ink.Space.xs)
        // Seamless paper fade beneath the slim floating bar so scrolling prose melts out softly.
        .background {
            Ink.paper.ignoresSafeArea(edges: .top)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [Ink.paper, Ink.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Ink.Space.m)
                .offset(y: Ink.Space.m)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    var headerBack: some View {
        Button(action: leave) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: Ink.Size.body, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                .glassFace(in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("打开侧边栏")
    }

    var headerIdentity: some View {
        HStack(spacing: Ink.Space.s) {
            PetStill(size: 28 * UIScale.factor, state: petState, avatar: true, bot: isRoom ? nil : bot)
                .breathing(working, tint: Ink.accent)
                // Its face opens a glance at it: what it does, what it made, its schedule.
                .onTapGesture {
                    guard !isRoom else { detailOpen = true; return }
                    Haptics.light()
                    glancing = true
                }
                .popover(isPresented: $glancing) {
                    GlanceCard(team: team, bot: bot, key: chat.key, availableWidth: chatViewport.width,
                               openCard: { glancing = false; cardOpen = true },
                               openDetail: { glancing = false; detailOpen = true })
                        .presentationCompactAdaptation(.popover)
                }
            headerTitle
        }
        .padding(.leading, Ink.Space.s)
        .padding(.trailing, Ink.Space.m)
        .padding(.vertical, largeText ? Ink.Space.s : 0)
        .frame(minHeight: Ink.Bar.height)
        .glassBacking(in: Capsule())
    }

    var headerTitle: some View {
        Button {
            Haptics.light()
            typing = false
            detailOpen = true
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .font(.system(size: Ink.Size.sub * (largeText ? textScale : 1), weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                HStack(spacing: Ink.Space.xs) {
                    Circle()
                        .fill(working ? Ink.accent : Ink.ok)
                        .frame(width: 5.5, height: 5.5)
                    Text(headerLine)
                        .font(largeText ? .footnote : .system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(largeText ? nil : 1)
                        .fixedSize(horizontal: false, vertical: largeText)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.5), value: headerLine)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L.t("chat.details"))
    }

    var headerControls: some View {
        HStack(spacing: Ink.Space.xs) {
            ChatBrowserIndicator(browser: team.browser) {
                typing = false
                roaming = true
            }
            if largeText {
                headerMoreMenu
                    .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                    .glassBacking(in: Circle())
            } else {
                HStack(spacing: 0) {
                    modelMenu(compact: true)
                    Rectangle()
                        .fill(Ink.rule.opacity(0.75))
                        .frame(width: 0.5, height: 18 * UIScale.factor)
                    headerMoreMenu
                        .frame(width: 40 * UIScale.factor, height: Ink.Bar.height)
                }
                .frame(height: Ink.Bar.height)
                .glassBacking(in: Capsule())
            }
        }
    }

    var headerMoreMenu: some View {
        Menu {
            Section {
                chatMenuButton("chat.newConversation", icon: "square.and.pencil") {
                    typing = false
                    side.fresh(isRoom ? nil : bot.id)
                }
                chatMenuButton("actions.share", icon: "square.and.arrow.up") {
                    let title = team.title(of: chat.key) ?? bot.name
                    Task {
                        if let url = await team.exportChat(chat.key, title: title) {
                            sharing = ShareFile(url: url)
                        } else {
                            exportFailed = true
                        }
                    }
                }
                chatMenuButton("chat.find", icon: "magnifyingglass") { startFinding() }
                if !following { chatMenuButton("chat.latest", icon: "arrow.down.to.line") { returnToLatest() } }
            }
            Section {
                chatMenuButton("chat.compactContext", icon: "rectangle.compress.vertical") {
                    Task { _ = try? await team.compress(chat.key) }
                }
                Button(L.t("actions.clear"), systemImage: "trash", role: .destructive) {
                    typing = false
                    clearingChat = true
                }
            }
            Section {
                chatMenuButton("nav.terminal", icon: "terminal") { terminalOpen = true }
                chatMenuButton("nav.browser", icon: "safari") { roaming = true }
                chatMenuButton("chat.files", icon: "folder") { filesOpen = true }
            }
            Section {
                chatMenuButton("agent.skills", icon: "books.vertical") { chatSkillsOpen = true }
                chatMenuButton("chat.mcp", icon: "point.3.connected.trianglepath.dotted") { chatConnectorsOpen = true }
            }
            Section {
                chatMenuButton("chat.outline", icon: "list.bullet.indent") {
                    Task {
                        await loadEverything()
                        outlinePairs = outline
                        outlining = true
                    }
                }
                chatMenuButton("chat.conversationHistory", icon: "book.pages") { leafing = true }
                chatMenuButton("chat.rename", icon: "pencil") {
                    renameText = team.title(of: chat.key) ?? ""
                    renaming = true
                }
                if !isRoom { chatMenuButton("chat.openCard", icon: "person.text.rectangle") { cardOpen = true } }
                if working { chatMenuButton("alwaysOn.open", icon: "moon.stars") { AlwaysOn.show(chat: chat.key) } }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Ink.Size.body, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L.t("chat.menu"))
    }

    func chatMenuButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(L.t(key), systemImage: icon) {
            typing = false
            action()
        }
    }
}

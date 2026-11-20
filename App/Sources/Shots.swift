import SwiftUI
import UIKit

/// Screenshots for checking the look without a phone: CI launches Clio in the simulator with `-clioShot <screen>`
/// (the argument lands in UserDefaults), Clio fills in the demo and opens that screen, and CI takes the picture.
enum Shots {
    static var name: String? { UserDefaults.standard.string(forKey: "clioShot") }

    static var startsInChat: Bool {
        switch name {
        case "chat", "sidebar", "plan", "model-error": true
        default: false
        }
    }

    static var readyToken: String? { UserDefaults.standard.string(forKey: "clioShotToken") }
}

/// Draw the requested settings page directly, so CI does not have to wait for two presentations.
struct ShotSettingsPage: View {
    let name: String
    @ObservedObject var team: TeamModel

    static let names: Set<String> = ["settings", "connectors", "look", "grants", "add", "pet"]

    var body: some View {
        switch name {
        case "settings": SettingsView(team: team, onLeaveDemo: {}, openElsewhere: { _ in })
        case "connectors": ConnectorsPage()
        case "look": LookPage()
        case "grants": GrantsPage(team: team)
        case "add": SetupView(team: team, onDone: {})
        case "pet": PetPage()
        default: EmptyView()
        }
    }
}

/// Signal the simulator after the screen has a window and had two opportunities to draw.
struct ShotReady: UIViewRepresentable {
    let token: String

    func makeUIView(context: Context) -> Probe { Probe(token: token) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private let token: String
        private var displayLink: CADisplayLink?
        private var frames = 0

        init(token: String) {
            self.token = token
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil, frames < 2 else { return }
            let link = CADisplayLink(target: self, selector: #selector(didRefresh))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func didRefresh() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            frames += 1
            guard frames == 2 else { return }
            displayLink?.invalidate()
            displayLink = nil
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("clio-shot-ready")
            try? token.write(to: marker, atomically: true, encoding: .utf8)
        }
    }
}

/// For screenshots only: every figure in every pose, with and without its frame, and as a pet on a bar.
struct FigureGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                ForEach(Persona.Kind.figures, id: \.self) { kind in
                    Text(kind.word).font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.inkSoft)
                    HStack(spacing: Ink.Space.s) {
                        ForEach(WhalePose.allCases, id: \.self) { pose in
                            Whale(size: 54, pose: pose, persona: persona(kind, .circle))
                        }
                    }
                    HStack(alignment: .bottom, spacing: Ink.Space.m) {
                        ForEach([WhalePose.idle, .writing, .sleeping], id: \.self) { pose in
                            PetFigureSample(kind: kind, pose: pose)
                        }
                    }
                    .padding(.bottom, Ink.Space.s)
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.top, Ink.Space.xl)
        }
    }

    private func persona(_ kind: Persona.Kind, _ frame: Persona.Frame) -> Persona {
        var persona = Persona()
        persona.kind = kind
        persona.frame = frame
        return persona
    }
}

/// A figure as a pet, standing on a strip like the composer's top edge.
private struct PetFigureSample: View {
    var kind: Persona.Kind
    var pose: WhalePose

    var body: some View {
        var persona = Persona()
        persona.kind = kind
        persona.frame = .bare
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Whale(size: 44, pose: pose, persona: persona)
            }
            Capsule().fill(Ink.paperRaised).frame(width: 90, height: 14)
                .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))
        }
    }
}

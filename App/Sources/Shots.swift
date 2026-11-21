import SwiftUI
import UIKit

/// Screenshots for checking the look without a phone: CI launches Clio in the simulator with `-clioShot <screen>`
/// (the argument lands in UserDefaults), Clio fills in the demo and opens that screen, and CI takes the picture.
enum Shots {
    static var name: String? { UserDefaults.standard.string(forKey: "clioShot") }

    static var startsInChat: Bool {
        switch name {
        case "chat", "sidebar", "plan", "model-error": true
        default: name?.hasPrefix("chat-") == true
        }
    }

    /// Scenes that need more than the opening picture: a long conversation, one jumped back to its foot, one with a
    /// reply arriving. They wait `clioShotDelay` seconds after the first frames before saying they are ready.
    static var delay: Double { UserDefaults.standard.double(forKey: "clioShotDelay") }

    static var readyToken: String? { UserDefaults.standard.string(forKey: "clioShotToken") }
}

/// Draw the requested settings page directly, so CI does not have to wait for two presentations.
struct ShotSettingsPage: View {
    let name: String
    @ObservedObject var team: TeamModel

    static let names: Set<String> = ["settings", "connectors", "look", "grants", "add", "pet"]

    var body: some View {
        switch name {
        case "settings": SettingsView(team: team)
        case "connectors": ConnectorsPage()
        case "look": NavigationStack { LookPage() }
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
            let token = token
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Shots.delay)) {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("clio-shot-ready")
                try? token.write(to: marker, atomically: true, encoding: .utf8)
            }
        }
    }
}

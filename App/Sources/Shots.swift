import SwiftUI

/// Screenshots for checking the look without a phone: CI launches Clio in the simulator with `-clioShot <screen>`
/// (the argument lands in UserDefaults), Clio fills in the demo and opens that screen, and CI takes the picture.
enum Shots {
    static var name: String? { UserDefaults.standard.string(forKey: "clioShot") }
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

import SwiftUI
import UIKit

/// A button revealed when a row is pushed left.
struct SwipeAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var tint: Color
    var act: () -> Void
}

/// A row that slides left to show a few actions, like Mail's. Vertical scrolling is left alone:
/// the slide only starts when the finger moves mostly sideways.
struct SwipeRow<Content: View>: View {
    var actions: [SwipeAction]
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    private let width: CGFloat = 76

    private var reach: CGFloat { width * CGFloat(actions.count) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        Haptics.tick(0.6)
                        close()
                        action.act()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.symbol).font(.system(size: Ink.Size.body, weight: .medium))
                            Text(action.title).font(.system(size: Ink.Size.small, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(action.tint)
                    }
                    .buttonStyle(TapStyle())
                }
            }
            .clipShape(.rect(cornerRadius: Ink.Radius.small))
            .opacity(offset < -2 ? 1 : 0)

            content()
                .background(Ink.paper)
                .offset(x: offset)
                .overlay {
                    if settled < 0 {
                        Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                    }
                }
        }
        .gesture(SidewaysPan(changed: { moved in
            let target = settled + moved
            offset = target > 0 ? target / 4 : max(target, -reach - 40)
        }, ended: { moved, speed in
            let target = settled + moved
            let open = target < -reach / 2 || speed < -500
            withAnimation(Ink.Motion.settle) {
                offset = open && speed < 300 ? -reach : 0
                settled = offset
            }
            if offset < 0 { Haptics.tick(0.4) }
        }))
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { action.act() }
            }
        }
    }

    private func close() {
        withAnimation(Ink.Motion.settle) {
            offset = 0
            settled = 0
        }
    }
}

/// A pan that only begins when the finger moves more sideways than up or down.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ moved: CGFloat, _ speed: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let moved = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            changed(moved)
        case .ended, .cancelled, .failed:
            ended(moved, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return abs(speed.x) > abs(speed.y) * 1.3
        }
    }
}

import SwiftUI
import UIKit

private struct PhotoZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var photoZoomNamespace: Namespace.ID? {
        get { self[PhotoZoomNamespaceKey.self] }
        set { self[PhotoZoomNamespaceKey.self] = newValue }
    }
}

struct PhotoZoomSourceModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct PhotoZoomDestinationModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// Photos already fetched from the computer, small and full size.
@MainActor
private enum PhotoCache {
    static let store = NSCache<NSString, UIImage>()
}

/// A photo the computer keeps, shown small in a chat.
struct RemotePhoto: View {
    let chat: ChatModel
    let attachmentId: String
    @Environment(\.photoZoomNamespace) private var zoomNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Ink.paperRaised.opacity(0.7)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Ink.inkSoft)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .modifier(PhotoZoomSourceModifier(id: attachmentId, namespace: zoomNamespace, enabled: !reduceMotion))
        .contentShape(Rectangle())
        .task(id: attachmentId) {
            let key = "small-\(attachmentId)" as NSString
            if let kept = PhotoCache.store.object(forKey: key) { image = kept; return }
            if let data = await chat.photo(attachmentId, preview: true), let loaded = UIImage(data: data) {
                PhotoCache.store.setObject(loaded, forKey: key)
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// One photo full screen: pinch to zoom, double-tap to zoom, pan, or drag down to close.
struct PhotoViewer: View {
    let chat: ChatModel
    var attachmentId: String?
    var local: Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var isPinching = false
    @State private var isDragging = false
    @State private var dragSawPinch = false
    @State private var dragEligibleForDismiss = false
    @State private var panOffset: CGSize = .zero
    @State private var dragDelta: CGSize = .zero
    @State private var pull: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    private var settleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : Ink.Motion.unfold
    }

    private var dismissProgress: Double {
        guard zoom <= 1.01 else { return 0 }
        return min(1, Double(abs(pull.height)) / 300)
    }

    var body: some View {
        let activeScale = isPinching ? rubberBandedScale(for: zoom * pinch) : zoom
        let progress = dismissProgress
        let dismissScale: CGFloat = reduceMotion ? 1 : (1 - CGFloat(min(0.18, progress * 0.16)))
        let scrimOpacity = max(0.12, 1 - progress * 0.88)
        let activeOffset = resolvedImageOffset(for: activeScale)

        ZStack {
            Ink.Artwork.black
                .opacity(scrimOpacity)
                .ignoresSafeArea()

            GeometryReader { box in
                imageStage(
                    size: box.size,
                    activeScale: activeScale,
                    dismissScale: dismissScale,
                    activeOffset: activeOffset
                )
                .onAppear { containerSize = box.size }
                .onChange(of: box.size) { _, nextSize in
                    containerSize = nextSize
                    if zoom > 1.01 {
                        panOffset = clampedPan(panOffset, scale: zoom)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            closeButton(opacity: max(0, 1 - progress * 2.4))
        }
        .interactiveDismissDisabled(zoom > 1.01 || isPinching)
        .task {
            await loadImage()
        }
    }

    @ViewBuilder
    private func imageStage(
        size: CGSize,
        activeScale: CGFloat,
        dismissScale: CGFloat,
        activeOffset: CGSize
    ) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(activeScale * dismissScale)
                    .offset(
                        x: activeOffset.width + pull.width,
                        y: activeOffset.height + pull.height
                    )
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(Ink.Artwork.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(doubleTapGesture)
        .gesture(magnifyGesture)
        .simultaneousGesture(dragGesture)
    }

    private func closeButton(opacity: Double) -> some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: Ink.Size.body, weight: .bold))
                .foregroundStyle(Ink.Artwork.white)
                .frame(width: Ink.Bar.height, height: Ink.Bar.height)
                .background(Ink.Artwork.white.opacity(0.2), in: .circle)
        }
        .buttonStyle(TapStyle(grow: 8))
        .padding(.trailing, Ink.Space.l)
        .padding(.top, Ink.Space.s)
        .opacity(opacity)
        .accessibilityLabel(L.t("actions.close"))
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard image != nil else { return }
                withAnimation(settleAnimation) {
                    if zoom > 1.01 {
                        zoom = 1
                        pinch = 1
                        panOffset = .zero
                        dragDelta = .zero
                        pull = .zero
                    } else {
                        let targetZoom: CGFloat = 2.5
                        let center = CGPoint(x: containerSize.width * 0.5, y: containerSize.height * 0.5)
                        let dx = value.location.x - center.x
                        let dy = value.location.y - center.y
                        let desired = CGSize(
                            width: -dx * (targetZoom - 1),
                            height: -dy * (targetZoom - 1)
                        )
                        zoom = targetZoom
                        pinch = 1
                        panOffset = clampedPan(desired, scale: targetZoom)
                        dragDelta = .zero
                        pull = .zero
                    }
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard image != nil else { return }
                if !isPinching {
                    isPinching = true
                    dragSawPinch = true
                    dragEligibleForDismiss = false
                    pull = .zero
                    if dragDelta != .zero {
                        let committed = CGSize(
                            width: panOffset.width + dragDelta.width,
                            height: panOffset.height + dragDelta.height
                        )
                        panOffset = clampedPan(committed, scale: zoom)
                        dragDelta = .zero
                    }
                }
                pinch = value.magnification
            }
            .onEnded { value in
                isPinching = false
                guard image != nil else { return }
                let rawTarget = zoom * value.magnification
                let clamped = min(4, max(1, rawTarget))
                let resetToFit = rawTarget < 1 || clamped <= 1.01
                withAnimation(settleAnimation) {
                    if resetToFit {
                        zoom = 1
                        pinch = 1
                        panOffset = .zero
                        dragDelta = .zero
                    } else {
                        zoom = clamped
                        pinch = 1
                        panOffset = clampedPan(panOffset, scale: clamped)
                        dragDelta = .zero
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard image != nil else { return }
                if !isDragging {
                    isDragging = true
                    dragSawPinch = isPinching
                    dragEligibleForDismiss = !isPinching && zoom <= 1.01
                }
                if isPinching {
                    dragSawPinch = true
                    dragEligibleForDismiss = false
                    pull = .zero
                    return
                }
                if dragEligibleForDismiss {
                    pull = value.translation
                } else if zoom > 1.01 && !dragSawPinch {
                    dragDelta = value.translation
                }
            }
            .onEnded { value in
                let shouldDismissCheck = dragEligibleForDismiss && !dragSawPinch && !isPinching && zoom <= 1.01
                let shouldPanCommit = !dragSawPinch && !isPinching && zoom > 1.01
                isDragging = false
                dragEligibleForDismiss = false
                dragSawPinch = false
                guard image != nil else {
                    pull = .zero
                    dragDelta = .zero
                    return
                }
                if shouldDismissCheck {
                    let verticalDrag = abs(value.translation.height)
                    let predictedVertical = abs(value.predictedEndTranslation.height)
                    if verticalDrag > 110 || predictedVertical > 240 {
                        dismiss()
                    } else {
                        withAnimation(settleAnimation) {
                            pull = .zero
                        }
                    }
                } else if shouldPanCommit {
                    let combined = CGSize(
                        width: panOffset.width + value.translation.width,
                        height: panOffset.height + value.translation.height
                    )
                    let clamped = clampedPan(combined, scale: zoom)
                    dragDelta = .zero
                    withAnimation(settleAnimation) {
                        panOffset = clamped
                    }
                } else {
                    dragDelta = .zero
                    if pull != .zero {
                        withAnimation(settleAnimation) {
                            pull = .zero
                        }
                    }
                }
            }
    }

    private func rubberBandedScale(for raw: CGFloat) -> CGFloat {
        if raw < 1 {
            let over = 1 - raw
            let damped = over / (1 + over * 2.2)
            return max(0.65, 1 - damped * 0.45)
        }
        if raw > 4 {
            let over = raw - 4
            let damped = over / (1 + over * 0.65)
            return 4 + damped
        }
        return raw
    }

    private func fittedImageSize(in container: CGSize, image: UIImage) -> CGSize {
        guard container.width > 0, container.height > 0,
              image.size.width > 0, image.size.height > 0 else { return .zero }
        let ratio = min(container.width / image.size.width, container.height / image.size.height)
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    }

    private func maxPanOffset(for scale: CGFloat) -> CGSize {
        guard let image else { return .zero }
        let fitted = fittedImageSize(in: containerSize, image: image)
        return CGSize(
            width: max(0, (fitted.width * scale - containerSize.width) * 0.5),
            height: max(0, (fitted.height * scale - containerSize.height) * 0.5)
        )
    }

    private func clampedPan(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let limit = maxPanOffset(for: scale)
        return CGSize(
            width: min(limit.width, max(-limit.width, proposed.width)),
            height: min(limit.height, max(-limit.height, proposed.height))
        )
    }

    private func rubberBandedPan(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let limit = maxPanOffset(for: scale)
        func rubber(_ value: CGFloat, maxAbs: CGFloat) -> CGFloat {
            if abs(value) <= maxAbs { return value }
            let over = abs(value) - maxAbs
            let damped = over / (1 + over * 0.02)
            return (value >= 0 ? 1 : -1) * (maxAbs + damped * 0.35)
        }
        return CGSize(
            width: rubber(proposed.width, maxAbs: limit.width),
            height: rubber(proposed.height, maxAbs: limit.height)
        )
    }

    private func resolvedImageOffset(for scale: CGFloat) -> CGSize {
        guard scale > 1.01 else { return .zero }
        let combined = CGSize(
            width: panOffset.width + dragDelta.width,
            height: panOffset.height + dragDelta.height
        )
        return rubberBandedPan(combined, scale: scale)
    }

    private func loadImage() async {
        if let local { image = UIImage(data: local); return }
        guard let attachmentId else { return }
        let small = "small-\(attachmentId)" as NSString
        let full = "full-\(attachmentId)" as NSString
        // The small one shows until the original arrives.
        image = PhotoCache.store.object(forKey: full) ?? PhotoCache.store.object(forKey: small)
        guard PhotoCache.store.object(forKey: full) == nil else { return }
        if let data = await chat.photo(attachmentId, preview: false), let loaded = UIImage(data: data) {
            PhotoCache.store.setObject(loaded, forKey: full)
            image = loaded
        }
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onDone(image)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onDone(nil)
            parent.dismiss()
        }
    }
}

import AgentKit
import PhotosUI
import SwiftUI
import UIKit

/// Pure UIKit pet/companion avatar view matching `PetStill`.
@MainActor
final class ChatPetAvatarView: UIView {
    private let bgLayer = CALayer()
    private let imageView = UIImageView()
    private let fallbackView = UIImageView()

    private var isAvatarCircle = true
    private var currentWash: Color?
    private var lastConfiguredSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = false
        layer.addSublayer(bgLayer)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        fallbackView.image = UIImage(systemName: "person.crop.circle")
        fallbackView.contentMode = .scaleAspectFit
        fallbackView.isHidden = true
        addSubview(fallbackView)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatPetAvatarView, _) in
            view.lastConfiguredSignature = ""
            view.refreshColors()
        }
    }

    func configure(bot: BotInfo?, state: String = "idle", wash: Color? = nil, avatar: Bool = true) {
        let resolvedWash = UIColor(wash ?? Ink.accentWash).resolvedColor(with: traitCollection)
        let washSig = washColorSignature(resolvedWash)
        let photoPicture: UIImage?
        let photoToken: Int
        if avatar, let bot, bot.avatar == "photo", let picture = Avatars.image(bot.id) {
            photoPicture = picture
            photoToken = ObjectIdentifier(picture).hashValue
        } else {
            photoPicture = nil
            photoToken = 0
        }
        let signature = "\(bot?.id ?? "")|\(bot?.avatar ?? "")|\(state)|\(avatar ? 1 : 0)|\(PetLibrary.shared.choice)|\(PetLibrary.shared.packs.count)|\(wash != nil ? 1 : 0)|\(washSig)|\(traitCollection.userInterfaceStyle.rawValue)|\(photoToken)"
        if signature == lastConfiguredSignature && imageView.image != nil {
            return
        }

        isAvatarCircle = avatar
        currentWash = wash

        if let picture = photoPicture {
            lastConfiguredSignature = signature
            bgLayer.isHidden = true
            imageView.isHidden = false
            fallbackView.isHidden = true
            imageView.contentMode = .scaleAspectFill
            imageView.image = picture
            imageView.layer.magnificationFilter = .linear
            setNeedsLayout()
            return
        }

        let pack = resolvedPack(for: bot)
        if let pack,
           let animName = pack.anim(for: state) ?? pack.anim(for: "idle"),
           let anim = pack.animations[animName],
           let first = anim.frames.first,
           let cell = PetSheets.cell(pack, anim, first.i) {
            lastConfiguredSignature = signature
            bgLayer.isHidden = !avatar
            imageView.isHidden = false
            fallbackView.isHidden = true
            imageView.contentMode = .scaleAspectFit
            imageView.image = UIImage(cgImage: cell)
            imageView.layer.magnificationFilter = pack.pixelArt ? .nearest : .linear
        } else {
            lastConfiguredSignature = ""
            bgLayer.isHidden = !avatar
            imageView.image = nil
            imageView.isHidden = true
            fallbackView.isHidden = false
        }
        refreshColors(resolvedWash: resolvedWash)
        setNeedsLayout()
    }

    private func washColorSignature(_ color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return "\(Int((r * 255).rounded())),\(Int((g * 255).rounded())),\(Int((b * 255).rounded())),\(Int((a * 255).rounded()))"
        }
        return "\(color.cgColor.hashValue)"
    }

    private func resolvedPack(for bot: BotInfo?) -> PetPack? {
        if let chosen = bot?.avatar, chosen.hasPrefix("pet:") {
            let id = String(chosen.dropFirst(4))
            if let own = PetLibrary.shared.packs.first(where: { $0.id == id }) { return own }
        }
        return PetLibrary.shared.pack
    }

    private func refreshColors(resolvedWash: UIColor? = nil) {
        let color = (resolvedWash ?? UIColor(currentWash ?? Ink.accentWash).resolvedColor(with: traitCollection)).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.backgroundColor = color
        CATransaction.commit()
        fallbackView.tintColor = UIColor(Ink.inkFaint)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bgLayer.frame = bounds
        bgLayer.cornerRadius = side * 0.5
        CATransaction.commit()

        if bgLayer.isHidden && isAvatarCircle {
            imageView.frame = bounds
            imageView.layer.cornerRadius = side * 0.5
        } else {
            let inner = isAvatarCircle ? side * 0.78 : side
            let inset = (side - inner) * 0.5
            imageView.frame = CGRect(x: inset, y: inset, width: inner, height: inner)
            imageView.layer.cornerRadius = 0
            let fallbackInset = inset + inner * 0.12
            fallbackView.frame = CGRect(x: fallbackInset, y: fallbackInset, width: inner * 0.76, height: inner * 0.76)
        }
    }
}

/// Pure UIKit user avatar matching `MeAvatar` (with menu to choose character 「我」, pet pack, or photo).
@MainActor
final class ChatMeAvatarView: UIView, PHPickerViewControllerDelegate {
    weak var hostViewController: UIViewController?
    var onAvatarChanged: (() -> Void)?

    private let button = UIButton(type: .system)
    private let circleLayer = CAGradientLayer()
    private let charLabel = UILabel()
    private let petView = ChatPetAvatarView()
    private let photoView = UIImageView()
    private var lastRenderedSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        circleLayer.startPoint = CGPoint(x: 0.5, y: 0)
        circleLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(circleLayer)

        charLabel.text = "我"
        charLabel.textAlignment = .center
        charLabel.isUserInteractionEnabled = false
        addSubview(charLabel)

        addSubview(petView)

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.isUserInteractionEnabled = false
        addSubview(photoView)

        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "我的头像，点一下换"
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                let items = MainActor.assumeIsolated {
                    self?.makeMenuElements() ?? []
                }
                completion(items)
            }
        ])
        addSubview(button)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatMeAvatarView, _) in
            view.refreshDisplay()
        }
        refreshDisplay()
    }

    func refreshDisplay() {
        let face = UserDefaults.standard.string(forKey: "me.avatar") ?? ""
        let photoID: Int
        if face == "photo", let img = Avatars.image("me") {
            photoID = ObjectIdentifier(img).hashValue
        } else {
            photoID = 0
        }
        let resolvedPackID: String
        if face.hasPrefix("pet:") {
            let targetID = String(face.dropFirst(4))
            resolvedPackID = PetLibrary.shared.packs.first(where: { $0.id == targetID })?.id ?? "missing"
        } else {
            resolvedPackID = PetLibrary.shared.pack?.id ?? "none"
        }
        let theme = Theme.shared
        let signature = "\(face)|\(PetLibrary.shared.choice)|\(PetLibrary.shared.packs.count)|\(resolvedPackID)|\(photoID)|\(traitCollection.userInterfaceStyle.rawValue)|\(theme.key)|\(theme.white)|\(theme.oled)"
        guard signature != lastRenderedSignature else { return }
        lastRenderedSignature = signature

        if face == "photo", let photo = Avatars.image("me") {
            circleLayer.isHidden = true
            charLabel.isHidden = true
            petView.isHidden = true
            photoView.isHidden = false
            photoView.image = photo
        } else if face.hasPrefix("pet:") {
            let packID = String(face.dropFirst(4))
            circleLayer.isHidden = true
            charLabel.isHidden = true
            photoView.isHidden = true
            petView.isHidden = false
            let standIn = BotInfo(id: "me", name: "我", avatar: "pet:\(packID)")
            petView.configure(bot: standIn, state: "idle", wash: Ink.accentWash, avatar: true)
        } else {
            circleLayer.isHidden = false
            charLabel.isHidden = false
            petView.isHidden = true
            photoView.isHidden = true
            let accent = UIColor(Ink.accent).resolvedColor(with: traitCollection)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            circleLayer.colors = [accent.cgColor, accent.withAlphaComponent(0.84).cgColor]
            CATransaction.commit()
            charLabel.textColor = UIColor(Ink.paper)
        }
    }

    private func makeMenuElements() -> [UIMenuElement] {
        let currentFace = UserDefaults.standard.string(forKey: "me.avatar") ?? ""
        var actions: [UIMenuElement] = []
        actions.append(UIAction(
            title: "用一个字「我」",
            state: currentFace.isEmpty ? .on : .off
        ) { [weak self] _ in
            UserDefaults.standard.set("", forKey: "me.avatar")
            self?.refreshDisplay()
            self?.onAvatarChanged?()
        })

        for pack in PetLibrary.shared.packs {
            let target = "pet:\(pack.id)"
            actions.append(UIAction(
                title: pack.name,
                state: currentFace == target ? .on : .off
            ) { [weak self] _ in
                UserDefaults.standard.set(target, forKey: "me.avatar")
                self?.refreshDisplay()
                self?.onAvatarChanged?()
            })
        }

        actions.append(UIAction(
            title: "从相册选一张",
            image: UIImage(systemName: "photo")
        ) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        return actions
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        hostViewController?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                Avatars.save(image, for: "me")
                UserDefaults.standard.set("photo", forKey: "me.avatar")
                self?.refreshDisplay()
                self?.onAvatarChanged?()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circleLayer.frame = bounds
        circleLayer.cornerRadius = side * 0.5
        CATransaction.commit()
        charLabel.font = UIFont.systemFont(ofSize: side * 0.45, weight: .semibold)
        charLabel.frame = bounds
        petView.frame = bounds
        photoView.frame = bounds
        photoView.layer.cornerRadius = side * 0.5
        button.frame = bounds
    }
}

/// Pure UIKit thumbnail loader matching `RemotePhoto` with `NSCache` and tap callback.
@MainActor
final class ChatRemotePhotoView: UIView {
    private static let cache = NSCache<NSString, UIImage>()

    var onPrepareTouch: ((String) -> Void)?
    var onCancelTouch: ((String) -> Void)?
    var onTap: ((String) -> Void)?
    var currentImage: UIImage? { imageView.image }

    func frameInWindow() -> CGRect? {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        return convert(bounds, to: nil)
    }

    private let imageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let tapButton = UIButton(type: .custom)

    private var currentAttachmentID = ""
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)

        placeholderIcon.image = UIImage(systemName: "photo")
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.isHidden = true
        addSubview(placeholderIcon)

        spinner.hidesWhenStopped = true
        addSubview(spinner)

        tapButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.currentAttachmentID.isEmpty else { return }
            self.onPrepareTouch?(self.currentAttachmentID)
        }, for: .touchDown)
        tapButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.currentAttachmentID.isEmpty else { return }
            self.onCancelTouch?(self.currentAttachmentID)
        }, for: [.touchUpOutside, .touchCancel])
        tapButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.currentAttachmentID.isEmpty else { return }
            Haptics.tick(0.5)
            self.onTap?(self.currentAttachmentID)
        }, for: .touchUpInside)
        addSubview(tapButton)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatRemotePhotoView, _) in
            view.refreshColors()
        }
        refreshColors()
    }

    func configure(chat: ChatModel, attachmentID: String) {
        guard currentAttachmentID != attachmentID else { return }
        loadTask?.cancel()
        currentAttachmentID = attachmentID
        layer.cornerRadius = Ink.Radius.small
        refreshColors()

        let key = "small-\(attachmentID)" as NSString
        if let hit = Self.cache.object(forKey: key) {
            imageView.image = hit
            placeholderIcon.isHidden = true
            spinner.stopAnimating()
            return
        }

        imageView.image = nil
        placeholderIcon.isHidden = true
        spinner.startAnimating()
        loadTask = Task { [weak self] in
            let data = await chat.photo(attachmentID, preview: true)
            guard !Task.isCancelled, let self, self.currentAttachmentID == attachmentID else { return }
            self.spinner.stopAnimating()
            if let data, let loaded = UIImage(data: data) {
                Self.cache.setObject(loaded, forKey: key)
                self.imageView.image = loaded
            } else {
                self.placeholderIcon.isHidden = false
            }
        }
    }

    func resetForReuse() {
        loadTask?.cancel()
        loadTask = nil
        currentAttachmentID = ""
        imageView.image = nil
        placeholderIcon.isHidden = true
        spinner.stopAnimating()
        onPrepareTouch = nil
        onCancelTouch = nil
        onTap = nil
    }

    private func refreshColors() {
        backgroundColor = UIColor(Ink.paperRaised).withAlphaComponent(0.7)
        placeholderIcon.tintColor = UIColor(Ink.inkSoft)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Ink.Radius.small
        imageView.frame = bounds
        tapButton.frame = bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let iconSide: CGFloat = 24
        placeholderIcon.frame = CGRect(
            x: (bounds.width - iconSide) * 0.5,
            y: (bounds.height - iconSide) * 0.5,
            width: iconSide,
            height: iconSide
        )
    }
}

/// Pure UIKit capsule pill for `SourcesRow`, presenting `SourcesSheet` via `hostViewController`.
@MainActor
final class ChatSourcesPillView: UIView {
    weak var hostViewController: UIViewController?
    var onOpenURL: ((URL) -> Void)?

    private let button = UIButton(type: .custom)
    private let label = UILabel()
    private let chevron = UIImageView()
    private var badgeContainers: [UIView] = []
    private var badgeImages: [UIImageView] = []
    private var badgeLetters: [UILabel] = []

    private var urls: [URL] = []
    private var titles: [URL: String] = [:]
    private var iconTasks: [Task<Void, Never>] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5

        for _ in 0..<3 {
            let container = UIView()
            container.clipsToBounds = true
            container.layer.borderWidth = 1.5
            let img = UIImageView()
            img.contentMode = .scaleAspectFit
            img.isHidden = true
            let letter = UILabel()
            letter.textAlignment = .center
            container.addSubview(img)
            container.addSubview(letter)
            addSubview(container)
            badgeContainers.append(container)
            badgeImages.append(img)
            badgeLetters.append(letter)
        }

        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: Ink.Size.micro, weight: .semibold))
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)

        button.addAction(UIAction { [weak self] _ in
            self?.presentSourcesSheet()
        }, for: .touchUpInside)
        addSubview(button)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatSourcesPillView, _) in
            view.refreshColors()
        }
        refreshColors()
    }

    func configure(urls: [URL], titles: [URL: String]) {
        let same = self.urls == urls && self.titles == titles
        self.urls = urls
        self.titles = titles
        guard !same else {
            refreshColors()
            return
        }

        iconTasks.forEach { $0.cancel() }
        iconTasks.removeAll(keepingCapacity: true)

        var seen: Set<String> = []
        let sites = urls.filter { seen.insert(SourcesRow.site($0)).inserted }
        let shownSites = Array(sites.prefix(3))

        for index in 0..<3 {
            let container = badgeContainers[index]
            let imgView = badgeImages[index]
            let letter = badgeLetters[index]
            if index < shownSites.count {
                let site = SourcesRow.site(shownSites[index])
                container.isHidden = false
                imgView.isHidden = true
                imgView.image = nil
                letter.isHidden = false
                letter.text = String(site.first ?? "?").uppercased()
                let task = Task { [weak self] in
                    let fetched = await BrandIcons.shared.icon(for: site)
                    guard !Task.isCancelled, let self, index < self.badgeImages.count else { return }
                    if let fetched {
                        self.badgeImages[index].image = fetched
                        self.badgeImages[index].isHidden = false
                        self.badgeLetters[index].isHidden = true
                    }
                }
                iconTasks.append(task)
            } else {
                container.isHidden = true
            }
        }

        label.font = UIFont.systemFont(ofSize: Ink.Size.micro, weight: .medium)
        label.text = "\(urls.count) 个来源"
        accessibilityLabel = "\(urls.count) 个来源，点开看"
        refreshColors()
        setNeedsLayout()
    }

    func resetForReuse() {
        iconTasks.forEach { $0.cancel() }
        iconTasks.removeAll(keepingCapacity: true)
        urls = []
        titles = [:]
        onOpenURL = nil
    }

    private func presentSourcesSheet() {
        guard !urls.isEmpty, let host = hostViewController else { return }
        Haptics.light()
        let onOpen = onOpenURL
        var sheetHolder: UIViewController?
        let sheet = SourcesSheet(urls: urls, titles: titles) { url in
            sheetHolder?.dismiss(animated: true) {
                onOpen?(url)
            }
        }
        let vc = UIHostingController(rootView: sheet)
        sheetHolder = vc
        if let presentation = vc.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
        }
        host.present(vc, animated: true)
    }

    private func refreshColors() {
        backgroundColor = UIColor(Ink.paperRaised)
        layer.borderColor = UIColor(Ink.rule).resolvedColor(with: traitCollection).withAlphaComponent(0.85).cgColor
        label.textColor = UIColor(Ink.inkSoft)
        chevron.tintColor = UIColor(Ink.inkFaint)
        let borderCG = UIColor(Ink.paperRaised).resolvedColor(with: traitCollection).cgColor
        for index in 0..<3 {
            let container = badgeContainers[index]
            container.backgroundColor = badgeImages[index].isHidden ? UIColor(Ink.inkSoft) : UIColor(Ink.Artwork.white)
            container.layer.borderColor = borderCG
            badgeLetters[index].textColor = UIColor(Ink.Artwork.white)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let iconSize = 16 * UIScale.factor
        let visibleCount = badgeContainers.filter { !$0.isHidden }.count
        let iconsWidth = visibleCount > 0 ? (iconSize + CGFloat(visibleCount - 1) * max(4, iconSize - 5)) : 0
        let labelFit = label.sizeThatFits(CGSize(width: size.width, height: ChatCellMetrics.sourcesPillHeight))
        let totalW = (6 * UIScale.factor)
            + iconsWidth
            + (visibleCount > 0 ? Ink.Space.s : 0)
            + ceil(labelFit.width)
            + Ink.Space.s
            + 10
            + (10 * UIScale.factor)
        return CGSize(width: min(size.width, ceil(totalW)), height: ChatCellMetrics.sourcesPillHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        layer.cornerRadius = h * 0.5
        button.frame = bounds

        let iconSize = 16 * UIScale.factor
        var x = 6 * UIScale.factor
        let visibleIndices = badgeContainers.indices.filter { !badgeContainers[$0].isHidden }
        for (order, idx) in visibleIndices.enumerated() {
            let container = badgeContainers[idx]
            container.frame = CGRect(x: x, y: (h - iconSize) * 0.5, width: iconSize, height: iconSize)
            container.layer.cornerRadius = iconSize * 0.5
            container.layer.zPosition = CGFloat(10 - order)
            badgeImages[idx].frame = container.bounds.insetBy(dx: iconSize * 0.14, dy: iconSize * 0.14)
            badgeLetters[idx].frame = container.bounds
            badgeLetters[idx].font = UIFont.systemFont(ofSize: iconSize * 0.44, weight: .bold)
            if order < visibleIndices.count - 1 {
                x += max(4, iconSize - 5)
            } else {
                x += iconSize
            }
        }
        if !visibleIndices.isEmpty { x += Ink.Space.s }

        let chevronW: CGFloat = 9
        let rightPad = 10 * UIScale.factor
        let labelMaxW = max(20, bounds.width - x - Ink.Space.s - chevronW - rightPad)
        let labelFit = label.sizeThatFits(CGSize(width: labelMaxW, height: h))
        label.frame = CGRect(x: x, y: 0, width: min(labelMaxW, ceil(labelFit.width)), height: h)
        chevron.frame = CGRect(x: bounds.width - rightPad - chevronW, y: (h - 10) * 0.5, width: chevronW, height: 10)
    }
}

/// Pure UIKit footer row under assistant replies (copy, retry, ⋯ menu, stats, and PetPerch clearance tracking).
@MainActor
final class ChatBotFooterView: UIView {
    var onCopy: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSpeak: (() -> Void)?
    var onQuote: (() -> Void)?
    var onSaveNote: (() -> Void)?
    var onLongNote: (() -> Void)?
    var onShare: (() -> Void)?
    var onFork: (() -> Void)?

    private let actionsCluster = UIView()
    private let copyButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let statsLabel = UILabel()

    private var showsRetry = false
    private var showsStats = false
    private var isRoom = false
    private var isSpeaking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(actionsCluster)

        configureIconButton(copyButton, symbol: "doc.on.doc", label: "复制") { [weak self] in
            self?.onCopy?()
        }
        configureIconButton(retryButton, symbol: "arrow.clockwise", label: "重来一次") { [weak self] in
            Haptics.light()
            self?.onRedo?()
        }
        configureIconButton(moreButton, symbol: "ellipsis", label: "更多", action: nil)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                let items = MainActor.assumeIsolated {
                    self?.makeMoreMenuElements() ?? []
                }
                completion(items)
            }
        ])

        actionsCluster.addSubview(copyButton)
        actionsCluster.addSubview(retryButton)
        actionsCluster.addSubview(moreButton)

        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: Ink.Size.micro, weight: .regular)
        statsLabel.textAlignment = .right
        statsLabel.adjustsFontSizeToFitWidth = true
        statsLabel.minimumScaleFactor = 0.8
        addSubview(statsLabel)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatBotFooterView, _) in
            view.refreshColors()
        }
        refreshColors()
    }

    private func configureIconButton(_ button: UIButton, symbol: String, label: String, action: (() -> Void)?) {
        let cfg = UIImage.SymbolConfiguration(pointSize: Ink.Size.small, weight: .regular)
        button.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        button.accessibilityLabel = label
        if let action {
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
    }

    func configure(row: ChatListRowItem) {
        let newest = row.isLatestBot
        showsRetry = newest
        showsStats = newest && row.showStats
        isRoom = row.isRoom
        isSpeaking = row.isSpeakingThisLine

        retryButton.isHidden = !showsRetry
        statsLabel.isHidden = !showsStats
        if showsStats {
            statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: Ink.Size.micro, weight: .regular)
            statsLabel.text = ChatPage.numbers(row.line)
        } else {
            statsLabel.text = nil
        }

        refreshColors()
        setNeedsLayout()
    }

    private func makeMoreMenuElements() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(
                title: isSpeaking ? "停止朗读" : "朗读",
                image: UIImage(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2")
            ) { [weak self] _ in self?.onSpeak?() },
            UIAction(
                title: "引用追问",
                image: UIImage(systemName: "text.quote")
            ) { [weak self] _ in self?.onQuote?() },
            UIAction(
                title: L.t("saveNote.title"),
                image: UIImage(systemName: "square.and.arrow.down.on.square")
            ) { [weak self] _ in self?.onSaveNote?() },
            UIAction(
                title: Words.t("做成长图"),
                image: UIImage(systemName: "photo.on.rectangle")
            ) { [weak self] _ in self?.onLongNote?() },
            UIAction(
                title: "分享",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.onShare?() },
        ]
        if !isRoom {
            items.append(UIAction(
                title: Words.t("从这里另起一叶"),
                image: UIImage(systemName: "arrow.triangle.branch")
            ) { [weak self] _ in self?.onFork?() })
        }
        return items
    }

    func actionsRectInWindow() -> CGRect {
        guard window != nil else { return .null }
        return actionsCluster.convert(actionsCluster.bounds, to: nil)
    }

    func resetForReuse() {
        showsRetry = false
        showsStats = false
        isRoom = false
        isSpeaking = false
        onCopy = nil
        onRedo = nil
        onSpeak = nil
        onQuote = nil
        onSaveNote = nil
        onLongNote = nil
        onShare = nil
        onFork = nil
    }

    private func refreshColors() {
        let faint = UIColor(Ink.inkFaint)
        copyButton.tintColor = faint
        retryButton.tintColor = faint
        moreButton.tintColor = faint
        statsLabel.textColor = faint.withAlphaComponent(0.85)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let btnSize: CGFloat = 28
        let gap = Ink.Space.xs
        let leadOffset: CGFloat = -5

        var x: CGFloat = 0
        copyButton.frame = CGRect(x: x, y: (h - btnSize) * 0.5, width: btnSize, height: btnSize)
        x += btnSize + gap
        if showsRetry {
            retryButton.frame = CGRect(x: x, y: (h - btnSize) * 0.5, width: btnSize, height: btnSize)
            x += btnSize + gap
        }
        moreButton.frame = CGRect(x: x, y: (h - btnSize) * 0.5, width: btnSize, height: btnSize)
        x += btnSize

        actionsCluster.frame = CGRect(x: leadOffset, y: 0, width: x, height: h)

        if showsStats {
            let statsX = actionsCluster.frame.maxX + Ink.Space.s
            let statsW = max(0, bounds.width - statsX)
            statsLabel.frame = CGRect(x: statsX, y: 0, width: statsW, height: h)
        }
    }
}

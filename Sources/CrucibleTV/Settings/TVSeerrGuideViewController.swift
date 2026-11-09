import CrucibleCore
import CrucibleDesign
import UIKit

/// Settings › Integrations › Seerr › Set Up Seerr on Apple TV: the five steps with what Crucible sees of each right now, and
/// two codes to scan with a phone: the whole guide with its commands, and Seerr's own setup page on the home network. Connect
/// appears the moment Seerr is ready.
final class TVSeerrGuideViewController: TVSettingsScaffold {
    private static let qrSide: CGFloat = 220

    private let env: TVAppEnvironment
    private let watcher: SeerrSetupWatcher
    private let onReady: (URL, SeerrPublicSettings) -> Void
    private let heading = TVSettingsHeading(title: SeerrGuide.title, body: SeerrGuide.intro)
    private let guideCode = TVSeerrGuideCode(caption: SeerrGuide.scanForGuide, side: qrSide)
    private let seerrCode = TVSeerrGuideCode(caption: SeerrGuide.scanForSeerr, side: qrSide)
    private var shownSetupURL: URL?

    init(env: TVAppEnvironment, onReady: @escaping (URL, SeerrPublicSettings) -> Void) {
        self.env = env
        watcher = SeerrSetupWatcher(api: env.api)
        self.onReady = onReady
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let codes = UIStackView(arrangedSubviews: [guideCode, seerrCode])
        codes.axis = .horizontal
        codes.alignment = .top
        codes.spacing = Theme.Space.l
        let column = UIStackView(arrangedSubviews: [heading, codes])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = Theme.Space.xl
        installContext(column)
        guideCode.show(SeerrGuide.webGuide.absoluteString, scale: traitCollection.displayScale)
        guideCode.accessibilityIdentifier = "seerrGuide.qr.guide"
        seerrCode.accessibilityIdentifier = "seerrGuide.qr.seerr"
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        watcher.start { [weak self] in self?.render() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        watcher.stop()
    }

    override var preferredFocusRowID: String? {
        watcher.seerr.isReady ? "seerrGuide.connect" : "seerrGuide.host"
    }

    private func render() {
        if !ServerOwnership.isOwner() { heading.setBody(SeerrGuide.intro + "\n\n" + SeerrGuide.notOwner) }
        let setupURL = watcher.setupURL
        if setupURL != shownSetupURL {
            shownSetupURL = setupURL
            seerrCode.show(setupURL?.absoluteString, scale: traitCollection.displayScale)
        }
        var rows: [TVRowItem] = []
        if case .ready = watcher.seerr {
            rows.append(TVRowItem(id: "seerrGuide.connect", title: SeerrCopy.connect, subtitle: SeerrGuide.readyToConnect, symbol: "link", accessory: .chevron))
        }
        rows.append(TVRowItem(id: "seerrGuide.host", title: SeerrGuide.hostQuestion, value: watcher.host.title, symbol: "server.rack", accessory: .chevron))
        for step in SeerrGuide.Step.allCases {
            let status = status(for: step)
            rows.append(TVRowItem(
                id: "seerrGuide.step.\(step.rawValue)",
                title: "\(step.rawValue + 1). \(SeerrGuide.title(step))",
                subtitle: SeerrGuide.summary(step, host: watcher.host, home: watcher.homeHost, server: watcher.serverName),
                value: status?.value,
                symbol: status?.symbol ?? "circle",
                isStatic: true
            ))
        }
        rows.append(TVRowItem(id: "seerrGuide.enterAddress", title: SeerrCopy.enterAddress, subtitle: SeerrGuide.otherAddress, symbol: "keyboard"))
        setRows(rows)
    }

    private func status(for step: SeerrGuide.Step) -> (value: String, symbol: String)? {
        switch step {
        case .install:
            switch watcher.seerr {
            case .looking: return nil
            case .notFound: return (SeerrGuide.statusNotYet, "circle.dashed")
            case .needsSetup, .notPlex, .ready: return (SeerrGuide.statusFound, "checkmark.circle.fill")
            }
        case .setUp:
            switch watcher.seerr {
            case .ready: return (SeerrGuide.statusDone, "checkmark.circle.fill")
            case .needsSetup: return (SeerrGuide.statusUnfinished, "circle.dashed")
            case .notPlex: return (SeerrGuide.statusWrongServer, "exclamationmark.triangle")
            case .looking, .notFound: return nil
            }
        case .away:
            return watcher.deviceOnTailnet ? (SeerrGuide.statusOn, "checkmark.circle.fill") : (SeerrGuide.statusOff, "circle.dashed")
        case .downloads, .people:
            return nil
        }
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case "seerrGuide.connect":
            guard case .ready(let url, let settings) = watcher.seerr else { return }
            onReady(url, settings)
        case "seerrGuide.enterAddress":
            presentTextEntry(title: SeerrCopy.addressTitle, message: SeerrCopy.addressMessage, text: "", placeholder: SeerrCopy.addressPlaceholder, keyboard: .URL, confirmTitle: SeerrGuide.lookThere) { [weak self] typed in
                self?.watcher.add(typed: typed)
            }
        case "seerrGuide.host":
            let hosts = SeerrHost.allCases
            let next = hosts[((hosts.firstIndex(of: watcher.host) ?? 0) + 1) % hosts.count]
            watcher.choose(next)
        default:
            break
        }
    }
}

/// A QR code on a white card with a caption under it; empty and hidden until it has something to show.
private final class TVSeerrGuideCode: UIView {
    private let card = UIView()
    private let image = UIImageView()
    private let caption = UILabel()
    private let side: CGFloat

    init(caption text: String, side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        card.backgroundColor = .white
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        image.layer.magnificationFilter = .nearest
        image.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(image)
        card.translatesAutoresizingMaskIntoConstraints = false
        caption.text = text
        caption.font = Theme.Font.caption1Regular
        caption.textColor = Theme.Color.labelSecondary
        caption.numberOfLines = 3
        caption.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [card, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.widthAnchor.constraint(equalTo: card.widthAnchor),
            card.widthAnchor.constraint(equalToConstant: side + 32),
            card.heightAnchor.constraint(equalToConstant: side + 32),
            image.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: side),
            image.heightAnchor.constraint(equalToConstant: side),
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String?, scale: CGFloat) {
        guard let text, let code = TVQRCode.image(for: text, side: side, scale: scale) else {
            isHidden = true
            return
        }
        image.image = code
        accessibilityValue = text
        isHidden = false
    }
}

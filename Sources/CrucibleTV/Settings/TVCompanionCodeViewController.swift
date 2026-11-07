import CoreImage
import CoreImage.CIFilterBuiltins
import CrucibleCore
import CrucibleDesign
import UIKit

/// The QR code an Apple TV shows to be added to Crucible Server: a secret made here that this Apple TV never sends. A
/// paired iPhone scans it and hands the secret to the server over its pinned connection; meanwhile this screen keeps
/// trying to pair with that secret beside the Plex server. Only someone who saw the code can prove it, so the code works
/// only while this screen waits, and the iPhone refuses it once it has expired.
final class TVCompanionCodeViewController: UIViewController {
    private let deadline = Date().addingTimeInterval(TVCompanionCodeViewController.lifetime)
    private lazy var device = CompanionDeviceInvite(name: UIDevice.current.name, secret: CompanionInvite.newSecret(), expires: deadline)
    private let imageView = UIImageView()
    private let statusLabel = UILabel()
    private var waiting: Task<Void, Never>?
    private lazy var cancelButton = TVButton.make(.glass, title: String(localized: "Cancel")) { [weak self] in
        guard let self else { return }
        navigationController?.popViewController(animated: TVMotion.animationsEnabled)
    }
    var onPaired: (@MainActor () -> Void)?

    private static let lifetime: TimeInterval = 600

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        imageView.image = Self.qrImage(device.link.absoluteString)
        imageView.layer.magnificationFilter = .nearest
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.layer.cornerRadius = Theme.Radius.m
        imageView.clipsToBounds = true
        imageView.accessibilityIdentifier = "settings.crucibleServer.qr"
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = CompanionCopy.codeSteps

        let heading = UILabel()
        heading.font = Theme.Font.title2
        heading.textColor = Theme.Color.label
        heading.text = CompanionCopy.showCode
        heading.accessibilityTraits = .header
        let steps = UILabel()
        steps.font = Theme.Font.body
        steps.textColor = Theme.Color.labelSecondary
        steps.numberOfLines = 0
        steps.text = CompanionCopy.codeSteps
        statusLabel.font = Theme.Font.body
        statusLabel.textColor = Theme.Color.label
        statusLabel.numberOfLines = 0
        statusLabel.text = CompanionCopy.waitingForIPhone
        statusLabel.accessibilityIdentifier = "settings.crucibleServer.codeStatus"

        cancelButton.accessibilityIdentifier = "settings.crucibleServer.codeCancel"
        let text = UIStackView(arrangedSubviews: [heading, steps, statusLabel, cancelButton])
        text.alignment = .leading
        text.axis = .vertical
        text.spacing = Theme.Space.l
        let row = UIStackView(arrangedSubviews: [imageView, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.xl
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 520),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
            text.widthAnchor.constraint(equalToConstant: 860),
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        wait()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [cancelButton]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        waiting?.cancel()
    }

    private func wait() {
        let hosts = PreviouslyOnRequest.hostsBesidePlex()
        guard !hosts.isEmpty else {
            statusLabel.text = CompanionError.unreachable.message
            return
        }
        let invite = CompanionInvite(name: CompanionCopy.title, hosts: hosts, secret: device.secret, fingerprint: nil)
        let deadline = deadline
        waiting = Task { [weak self] in
            do throws(CompanionError) {
                let server = try await PreviouslyOnRequest.waitForHandOff(invite, deviceName: UIDevice.current.name, until: deadline)
                self?.statusLabel.text = CompanionCopy.paired(server.name)
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.onPaired?()
            } catch {
                guard !Task.isCancelled else { return }
                self?.statusLabel.text = error == .codeRefused ? CompanionCopy.codeExpired : error.message
            }
        }
    }

    /// A crisp QR code for `text`, drawn at its own module size and scaled by the image view without smoothing.
    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

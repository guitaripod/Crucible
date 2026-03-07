import UIKit

final class ServerSetupViewController: UIViewController {
    private let urlField = UITextField()
    private let connectButton = UIButton(configuration: .filled())
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    var onConnected: ((URL) -> Void)?
    private var connectTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Connect to Server"
        navigationItem.largeTitleDisplayMode = .never

        let iconImage = UIImageView(image: UIImage(systemName: "server.rack"))
        iconImage.tintColor = .systemBlue
        iconImage.contentMode = .scaleAspectFit
        iconImage.translatesAutoresizingMaskIntoConstraints = false
        iconImage.heightAnchor.constraint(equalToConstant: 60).isActive = true
        iconImage.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = "Crucible"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center

        urlField.placeholder = "http://192.168.1.100:8484"
        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.returnKeyType = .go
        urlField.clearButtonMode = .whileEditing

        connectButton.configuration?.title = "Connect"
        connectButton.configuration?.cornerStyle = .medium
        connectButton.addAction(UIAction { [unowned self] _ in connect() }, for: .touchUpInside)

        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [iconImage, titleLabel, urlField, connectButton, statusLabel, spinner])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -20),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        connectTask?.cancel()
    }

    private func connect() {
        var text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            showError("Enter a server URL")
            return
        }

        if !text.contains("://") {
            text = "http://\(text)"
        }

        guard let url = URL(string: text) else {
            showError("Invalid URL format")
            return
        }

        statusLabel.isHidden = true
        spinner.startAnimating()
        connectButton.isEnabled = false

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            let client = APIClient(baseURL: url)
            do {
                let health: HealthResponse = try await client.request(.health)
                guard !Task.isCancelled else { return }
                statusLabel.textColor = .systemGreen
                statusLabel.text = "Connected — v\(health.version)"
                statusLabel.isHidden = false
                spinner.stopAnimating()
                ServerBootstrap.save(serverURL: url)
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                onConnected?(url)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
                guard !Task.isCancelled else { return }
                showError("Cannot connect to server. Check the URL and try again.")
                spinner.stopAnimating()
                connectButton.isEnabled = true
            } catch let error as URLError where error.code == .timedOut {
                guard !Task.isCancelled else { return }
                showError("Connection timed out. Check your network.")
                spinner.stopAnimating()
                connectButton.isEnabled = true
            } catch {
                guard !Task.isCancelled else { return }
                showError(error.localizedDescription)
                spinner.stopAnimating()
                connectButton.isEnabled = true
            }
        }
    }

    private func showError(_ message: String) {
        statusLabel.textColor = .systemRed
        statusLabel.text = message
        statusLabel.isHidden = false
    }
}

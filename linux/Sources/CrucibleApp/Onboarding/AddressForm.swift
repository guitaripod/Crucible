import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The address field, its error line, the step under way and Connect (`TVAddressForm`), shared by onboarding and Settings.
/// Return in the field and Connect both submit; the screen around it parses the text and reports back through `setBusy`
/// and `showError`.
@MainActor
final class AddressForm: View {
    static let placeholder = String(localized: "192.168.1.20 or https://host:32400")

    var onSubmit: ((String) -> Void)?

    private let field = TextFieldView(placeholder: AddressForm.placeholder, symbol: nil)
    private let connect = ButtonView(style: .primary, title: String(localized: "Connect", comment: "Button that connects to the entered server address"))
    private var error: String?
    private var status: String?
    private var isBusy = false

    init(initialText: String?) {
        super.init()
        field.setText(initialText ?? "", notify: false)
        field.onChange = { [weak self] _ in
            guard self?.error != nil else { return }
            self?.error = nil
            self?.superview?.setNeedsLayout()
            self?.setNeedsLayout()
        }
        field.onSubmit = { [weak self] _ in self?.submit() }
        connect.onPress = { [weak self] in self?.submit() }
        [field, connect].forEach(addSubview)
    }

    override var preferredFocusView: View? { isBusy ? connect : field }
    override var remembersFocus: Bool { true }

    /// Busy disables the field and shows the step under way; Connect stays focusable so Escape still has somewhere to start.
    func setBusy(_ busy: Bool, status: String? = nil) {
        isBusy = busy
        self.status = busy ? status : nil
        connect.title = busy ? String(localized: "Connecting…") : String(localized: "Connect", comment: "Button that connects to the entered server address")
        if busy, field.isFocused { window?.focus.focus(connect, animated: false) }
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    func showError(_ message: String) {
        error = message
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    func updateStatus(_ text: String) {
        status = text
        setNeedsDisplay()
    }

    private func submit() {
        guard !isBusy else { return }
        onSubmit?(field.text)
    }

    private func line(_ text: String?, width: Float) -> TextLayout? {
        guard let text, !text.isEmpty else { return nil }
        return TextLayout(text, font: Theme.current.type.callout, maxWidth: width, maxLines: 3, alignment: .center, scale: window?.scale ?? 1)
    }

    private var errorHeight: Float { line(error, width: frame.width).map { $0.size.height + Theme.current.metrics.tv(16) } ?? 0 }
    private var statusHeight: Float { line(status, width: frame.width).map { $0.size.height + Theme.current.metrics.tv(16) } ?? 0 }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let errorLine = line(error, width: size.width).map { $0.size.height + metrics.tv(16) } ?? 0
        let statusLine = line(status, width: size.width).map { $0.size.height + metrics.tv(16) } ?? 0
        return Size(width: size.width, height: metrics.primaryControlHeight + metrics.tv(24) + errorLine + statusLine + metrics.primaryControlHeight)
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        field.frame = Rect(x: 0, y: 0, width: frame.width, height: metrics.primaryControlHeight)
        let size = connect.sizeThatFits(Size(width: frame.width, height: metrics.primaryControlHeight))
        let y = field.frame.maxY + metrics.tv(24) + errorHeight + statusHeight
        connect.frame = Rect(x: ((frame.width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
    }

    override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        var y = field.frame.maxY + metrics.tv(16)
        if let layout = line(error, width: frame.width) {
            context.text(layout, at: Point(x: ((frame.width - layout.size.width) / 2).rounded(), y: y), color: palette.destructive)
            y += layout.size.height + metrics.tv(16)
        }
        if let layout = line(status, width: frame.width) {
            context.text(layout, at: Point(x: ((frame.width - layout.size.width) / 2).rounded(), y: y), color: palette.labelSecondary)
        }
    }
}

/// Add by Address during onboarding (`TVAddressViewController`): an IP address, a hostname or a full URL; Crucible tries
/// https first, then http, and keeps the server's identity when it is the one the person was choosing.
@MainActor
final class AddressScreen: ScreenView {
    var onConnected: ((PlexConnection) -> Void)?

    private let token: String
    private let known: ServerChoice?
    private let heading: ScreenTitleView
    private let form = AddressForm(initialText: RememberedServerAddress.text)
    private var connectTask: Task<Void, Never>?

    init(token: String, known: ServerChoice?, message: String?) {
        self.token = token
        self.known = known
        heading = ScreenTitleView(title: String(localized: "Add by Address"), detail: Self.detail(for: known))
        super.init()
        heading.columnWidth = Theme.current.metrics.formColumn
        [heading, form].forEach(addSubview)
        form.onSubmit = { [weak self] text in self?.connect(text) }
        if let message { form.showError(message) }
    }

    override var preferredFocusView: View? { form }

    override func screenWillDisappear() {
        connectTask?.cancel()
        connectTask = nil
    }

    private static func detail(for known: ServerChoice?) -> String {
        let base = String(localized: "Enter your server’s IP address or hostname, such as 192.168.1.20 or a Tailscale name. The default port is 32400.")
        guard let known, TailnetPresence.isConnected, let note = ConnectRecovery.tailnetLookupNote(serverName: known.name) else { return base }
        return base + " " + note
    }

    private func connect(_ text: String) {
        guard connectTask == nil else { return }
        guard let address = ServerAddress.parse(text) else {
            form.showError(AddServerLookup.invalidAddressMessage)
            return
        }
        RememberedServerAddress.remember(address)
        form.setBusy(true, status: String(localized: "Connecting to \(address.host)…"))
        let token = token
        let known = known
        connectTask = Task { [weak self] in
            let outcome = await ServerDiscovery(token: token).connect(toAddress: address, known: known) { [weak self] progress in
                self?.form.updateStatus(progress.message)
            }
            guard let self, !Task.isCancelled else { return }
            self.connectTask = nil
            switch outcome {
            case .connected(let connection):
                self.onConnected?(connection)
            case .failed(let message), .needsAddress(let message?):
                self.form.setBusy(false)
                self.form.showError(message)
            case .needsAddress(nil), .cancelled:
                self.form.setBusy(false)
            }
        }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let width = min(metrics.formColumn, frame.width - metrics.sideMargin * 2)
        let titleHeight = heading.sizeThatFits(bounds.size).height
        let formHeight = form.sizeThatFits(Size(width: width, height: 0)).height
        let top = max(metrics.tv(120), ((frame.height - titleHeight - metrics.tv(60) - formHeight) / 2).rounded())
        heading.frame = Rect(x: 0, y: top, width: frame.width, height: titleHeight)
        form.frame = Rect(x: ((frame.width - width) / 2).rounded(), y: heading.frame.maxY + metrics.tv(60), width: width, height: formHeight)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

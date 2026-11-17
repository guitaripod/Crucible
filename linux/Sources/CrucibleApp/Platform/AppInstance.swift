import CLinuxServices
import Foundation
import Kiln

/// The one running Crucible: it owns `org.guitaripod.Crucible` on the session bus and serves
/// `org.freedesktop.Application`, so a later launch (a `crucible://` link, the menu entry clicked again) hands its links
/// and the launcher's activation token to it and quits instead of opening a second window.
@MainActor
final class AppInstance {
    enum Claim {
        case claimed(AppInstance)
        case forwarded
        case unavailable
    }

    /// Links a later launch handed over, and the token that brings the window to the front for it.
    var onOpen: ((_ urls: [URL], _ activationToken: String?) -> Void)?
    private let handle: OpaquePointer
    private weak var loop: EventLoop?
    private static weak var current: AppInstance?

    private init(handle: OpaquePointer, loop: EventLoop) {
        self.handle = handle
        self.loop = loop
        loop.add(fd: crucible_app_fd(handle)) { [weak self] _ in
            guard let self else { return }
            crucible_app_process(self.handle)
        }
        AppInstance.current = self
    }

    /// Becomes the running instance, or, when one already runs, hands it `urls` and the activation token and reports
    /// `.forwarded` so this launch can quit. Without a session bus every launch runs on its own.
    static func claim(loop: EventLoop, forwarding urls: [URL], activationToken: String?) -> Claim {
        var alreadyRunning = false
        if let handle = crucible_app_claim(handler, nil, &alreadyRunning) {
            return .claimed(AppInstance(handle: handle, loop: loop))
        }
        guard alreadyRunning else { return .unavailable }
        let texts = urls.map(\.absoluteString)
        let forwarded = withCStrings(texts) { pointers in
            crucible_app_forward(pointers.baseAddress, Int32(texts.count), activationToken)
        }
        return forwarded ? .forwarded : .unavailable
    }

    /// The links among the command line's arguments: `crucible://` ones (the desktop entry passes `%U`) and web
    /// addresses, which play through yt-dlp (`crucible https://…`).
    static func links(in arguments: [String]) -> [URL] {
        arguments.dropFirst().compactMap { argument in
            guard let url = URL(string: argument), let scheme = url.scheme?.lowercased(), ["crucible", "http", "https"].contains(scheme) else { return nil }
            return url
        }
    }

    /// The launcher's xdg-activation token for this launch, taken out of the environment as the protocol asks, so
    /// nothing this process starts reuses it.
    static func takeActivationToken() -> String? {
        guard let token = ProcessInfo.processInfo.environment["XDG_ACTIVATION_TOKEN"], !token.isEmpty else { return nil }
        unsetenv("XDG_ACTIVATION_TOKEN")
        return token
    }

    func close() {
        loop?.remove(fd: crucible_app_fd(handle))
        crucible_app_destroy(handle)
        if AppInstance.current === self { AppInstance.current = nil }
    }

    private static let handler: crucible_app_handler = { _, uris, count, token in
        let urls = (0..<Int(count)).compactMap { index -> URL? in
            guard let pointer = uris?[index] else { return nil }
            return URL(string: String(cString: pointer))
        }
        let activationToken = token.map { String(cString: $0) }
        MainActor.assumeIsolated {
            AppInstance.current?.onOpen?(urls, activationToken)
        }
    }

    /// Calls `body` with NUL-terminated copies of `strings` that live for the call.
    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer(body)
    }
}

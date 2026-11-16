#if os(iOS)
import SwiftUI
import Translation
import UIKit

/// Asks the person to download the languages a translation needs, with the system's own sheet. Translation shows that
/// sheet only from a SwiftUI view's translation task, so a one-point view hosts the task on the screen in front and
/// leaves once the person answered.
@available(iOS 26.0, *)
@MainActor
enum TranslationDownload {
    /// True once the languages are on the device; false when the person declined or nothing could show the sheet.
    static func run(source: String, target: String) async -> Bool {
        guard let host = frontmost() else { return false }
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        var configuration = TranslationSession.Configuration(source: from, target: to)
        if #available(iOS 26.4, *) { configuration = TranslationSession.Configuration(source: from, target: to, preferredStrategy: .highFidelity) }
        let prompt = DownloadPrompt()
        return await withCheckedContinuation { continuation in
            prompt.continuation = continuation
            let hosting = UIHostingController(rootView: DownloadTaskView(configuration: configuration, prompt: prompt))
            hosting.view.backgroundColor = .clear
            hosting.view.isUserInteractionEnabled = false
            hosting.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            host.addChild(hosting)
            host.view.addSubview(hosting.view)
            hosting.didMove(toParent: host)
            prompt.controller = hosting
        }
    }

    /// The controller on top of the active window, which the sheet is shown over.
    private static func frontmost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// One download request: the view that hosts it and the answer it waits for, given once.
@available(iOS 26.0, *)
@MainActor
final class DownloadPrompt {
    var controller: UIViewController?
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ ready: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        controller?.willMove(toParent: nil)
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        controller = nil
        continuation.resume(returning: ready)
    }
}

/// The view whose translation task asks for the download.
@available(iOS 26.0, *)
struct DownloadTaskView: View {
    let configuration: TranslationSession.Configuration
    let prompt: DownloadPrompt

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration, action: Self.prepare(reportingTo: prompt))
    }

    /// The task's work, made outside the main actor so the session stays with it.
    nonisolated private static func prepare(reportingTo prompt: DownloadPrompt) -> (TranslationSession) async -> Void {
        { session in
            do {
                try await session.prepareTranslation()
                await prompt.finish(true)
            } catch {
                await prompt.finish(false)
            }
        }
    }
}
#endif

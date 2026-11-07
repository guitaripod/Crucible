import CrucibleCore
import CrucibleDesign
import MidgarCore
import Network
import UIKit

/// Lets a nearby Apple TV pair with Crucible Server through this iPhone. While the iPhone is paired it advertises the
/// `crucible-pair` application service; when someone picks it in the Apple TV's device picker, the system connects the
/// two over its encrypted link, the Apple TV names itself, and the iPhone asks before handing it a fresh pairing.
@MainActor
final class CompanionAdvertiser {
    static let shared = CompanionAdvertiser()

    private var listener: NWListener?
    private var active: NWConnection?
    private let queue = DispatchQueue(label: "com.guitaripod.crucible.companion-handoff")

    /// Advertises while this device is paired, and stops when it is not.
    func refresh() {
        if CompanionStore.current() == nil {
            listener?.cancel()
            listener = nil
        } else if listener == nil {
            start()
        }
    }

    private func start() {
        do {
            let listener = try NWListener(service: NWListener.Service(applicationService: CompanionHandOff.serviceName), using: .applicationService)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in CompanionAdvertiser.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                guard case .failed(let error) = state else { return }
                MidgarLog.error("Crucible Server hand-off listener failed: \(error)", category: .networking)
                Task { @MainActor in CompanionAdvertiser.shared.listener = nil }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            MidgarLog.error("Crucible Server hand-off listener could not start: \(error)", category: .networking)
        }
    }

    /// Takes one Apple TV at a time; another that connects meanwhile is turned away.
    private func accept(_ connection: NWConnection) {
        guard active == nil else {
            connection.cancel()
            return
        }
        active = connection
        Task { @MainActor in
            do throws(CompanionHandOffChannel.Failure) {
                try await CompanionHandOffChannel.ready(connection, queue: queue)
                let line = try await CompanionHandOffChannel.readLine(from: connection, timeout: .seconds(20))
                guard let device = CompanionHandOff.deviceName(inHello: line) else {
                    finish(connection)
                    return
                }
                ask(device, connection)
            } catch {
                finish(connection)
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        if active === connection { active = nil }
    }

    /// Calls `ended` once the Apple TV closes the link or it fails, which a pending read is the only way to notice;
    /// anything the Apple TV sends meanwhile is read and dropped.
    private nonisolated func watchForEnd(of connection: NWConnection, _ ended: @escaping @MainActor @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: CompanionHandOff.maximumLine) { [weak self] _, _, isComplete, error in
            guard isComplete || error != nil else {
                self?.watchForEnd(of: connection, ended)
                return
            }
            Task { @MainActor in ended() }
        }
    }

    private func ask(_ device: String, _ connection: NWConnection) {
        guard let client = PreviouslyOnRequest.client(), let host = Self.topPresented() else {
            answer(.declined, on: connection)
            if let host = Self.topPresented() { CompanionPairingFlow.show(CompanionCopy.pairThisIPhoneFirst, from: host) }
            return
        }
        let alert = UIAlertController(title: CompanionCopy.handOffQuestion(device: device, server: client.server.name), message: nil, preferredStyle: .alert)
        watchForEnd(of: connection) { [weak self, weak alert] in
            if let alert, alert.presentingViewController != nil { alert.dismiss(animated: true) }
            self?.finish(connection)
        }
        alert.addAction(UIAlertAction(title: CompanionCopy.dontAllow, style: .cancel) { [weak self] _ in self?.answer(.declined, on: connection) })
        alert.addAction(UIAlertAction(title: CompanionCopy.allow, style: .default) { [weak self] _ in
            Task { @MainActor in
                do throws(CompanionError) {
                    let invite = try await client.inviteForNearbyDevice()
                    guard self?.active === connection else { return }
                    Haptics.success()
                    self?.answer(.invite(invite), on: connection)
                } catch {
                    self?.answer(.declined, on: connection)
                    if let host = Self.topPresented() { CompanionPairingFlow.show(error.message, from: host) }
                }
            }
        })
        host.present(alert, animated: true)
    }

    private func answer(_ answer: CompanionHandOff.Answer, on connection: NWConnection) {
        Task { @MainActor in
            try? await CompanionHandOffChannel.send(CompanionHandOff.answerLine(answer), on: connection)
            try? await Task.sleep(for: .seconds(2))
            finish(connection)
        }
    }

    private static func topPresented() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

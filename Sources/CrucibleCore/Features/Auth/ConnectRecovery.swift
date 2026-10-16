import Foundation

/// What to tell a person whose server could not be reached automatically: the few things that
/// actually cause it, in the order worth trying, each with the one action that fixes it. Built from
/// facts only, so every screen that falls back to typing an address says the same thing.
///
/// ```swift
/// let recovery = ConnectRecovery(serverName: "Arch", advertisesLocalRoute: true, tailnetConnected: true, access: .none)
/// recovery.steps // [.findOnTailnet, .allowLocalNetwork]
/// ```
package struct ConnectRecovery: Equatable, Sendable {
    package enum Step: Equatable, Sendable {
        case connectTailscale
        case allowLocalNetwork
        case findOnTailnet
        case replaceTailnetToken
        case notOnTailnet
    }

    package let serverName: String?
    package let steps: [Step]

    package init(serverName: String?, advertisesLocalRoute: Bool, tailnetConnected: Bool, access: TailnetAccess.State) {
        self.serverName = serverName
        var steps: [Step] = []
        if tailnetConnected {
            switch access {
            case .none: steps.append(.findOnTailnet)
            case .rejected: steps.append(.replaceTailnetToken)
            case .saved: steps.append(.notOnTailnet)
            }
        } else {
            steps.append(.connectTailscale)
        }
        if advertisesLocalRoute { steps.append(.allowLocalNetwork) }
        self.steps = steps
    }

    package init(server: ServerChoice, tailnetConnected: Bool, access: TailnetAccess.State) {
        self.init(
            serverName: server.name,
            advertisesLocalRoute: server.routes.contains { $0.kind == .local },
            tailnetConnected: tailnetConnected,
            access: access
        )
    }

    /// One sentence for a screen that has no room for the step list, such as Apple TV, where a
    /// token cannot be typed: what to check about Tailscale before typing an address.
    package static func addressAdvice(tailnetConnected: Bool) -> String {
        tailnetConnected
            ? "If it's on your Tailscale network, enter its Tailscale address, which starts with 100."
            : "If it's on Tailscale, turn Tailscale on for this device and try again."
    }

    package var headline: String {
        guard let serverName else { return "Crucible couldn't connect automatically." }
        return "Crucible couldn't reach \(serverName)."
    }

    package func title(of step: Step) -> String {
        switch step {
        case .connectTailscale: return "Is your server on Tailscale?"
        case .allowLocalNetwork: return "Local Network access"
        case .findOnTailnet: return "Search your tailnet"
        case .replaceTailnetToken: return "Your Tailscale token stopped working"
        case .notOnTailnet: return "Not found on your tailnet"
        }
    }

    package func detail(of step: Step) -> String {
        let server = serverName ?? "your server"
        switch step {
        case .connectTailscale:
            return "Connect the Tailscale app, come back, and Crucible looks again on its own."
        case .allowLocalNetwork:
            return "Crucible needs it to find a server on your Wi-Fi. Turn it on for Crucible in Settings."
        case .findOnTailnet:
            return "You're on Tailscale, but \(server) isn't named like any machine on it. Give Crucible read access to your device list and it asks each computer."
        case .replaceTailnetToken:
            return "It expired or was revoked. Add a new one and Crucible searches your tailnet again."
        case .notOnTailnet:
            return "Crucible asked the online computers on your tailnet and none of them answered as \(server). Check that Plex is running."
        }
    }

    package func actionTitle(of step: Step) -> String? {
        switch step {
        case .connectTailscale: return "Open Tailscale"
        case .allowLocalNetwork: return "Open Settings"
        case .findOnTailnet: return "Search My Tailnet"
        case .replaceTailnetToken: return "Add a New Token"
        case .notOnTailnet: return nil
        }
    }

    package func symbol(of step: Step) -> String {
        switch step {
        case .connectTailscale, .findOnTailnet, .replaceTailnetToken, .notOnTailnet: return "network"
        case .allowLocalNetwork: return "wifi"
        }
    }
}

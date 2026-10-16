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
        case enterTailnetName
    }

    package let serverName: String?
    package let steps: [Step]

    /// A device with no way to type a long token, such as Apple TV, passes `canUseToken: false`
    /// and is told to enter the machine's name instead of being offered a search it cannot start.
    package init(serverName: String?, advertisesLocalRoute: Bool, tailnetConnected: Bool, access: TailnetAccess.State, canUseToken: Bool = true) {
        self.serverName = serverName
        var steps: [Step] = []
        if tailnetConnected {
            if canUseToken {
                switch access {
                case .none: steps.append(.findOnTailnet)
                case .rejected: steps.append(.replaceTailnetToken)
                case .saved: steps.append(.notOnTailnet)
                }
            } else {
                steps.append(.enterTailnetName)
            }
        } else {
            steps.append(.connectTailscale)
        }
        if advertisesLocalRoute { steps.append(.allowLocalNetwork) }
        self.steps = steps
    }

    package init(server: ServerChoice, tailnetConnected: Bool, access: TailnetAccess.State, canUseToken: Bool = true) {
        self.init(
            serverName: server.name,
            advertisesLocalRoute: server.routes.contains { $0.kind == .local },
            tailnetConnected: tailnetConnected,
            access: access,
            canUseToken: canUseToken
        )
    }

    /// What Crucible already tried on the tailnet, said where a person is about to type an address:
    /// the names it looked for, so the right one is a correction rather than a guess. Nil when the
    /// server's name leaves nothing to try.
    package static func tailnetLookupNote(serverName: String) -> String? {
        let names = MagicDNSName.candidates(forServerNamed: serverName)
        guard !names.isEmpty else { return nil }
        return "Crucible looked for \(names.map { "“\($0)”" }.joined(separator: ", ")) on your tailnet."
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
        case .enterTailnetName: return "Enter its Tailscale name"
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
        case .enterTailnetName:
            return "\(server) isn't named like any machine on your tailnet. Add it by address."
        }
    }

    package func actionTitle(of step: Step) -> String? {
        switch step {
        case .connectTailscale: return "Open Tailscale"
        case .allowLocalNetwork: return "Open Settings"
        case .findOnTailnet: return "Search My Tailnet"
        case .replaceTailnetToken: return "Add a New Token"
        case .notOnTailnet, .enterTailnetName: return nil
        }
    }

    package func symbol(of step: Step) -> String {
        switch step {
        case .connectTailscale, .findOnTailnet, .replaceTailnetToken, .notOnTailnet, .enterTailnetName: return "network"
        case .allowLocalNetwork: return "wifi"
        }
    }
}

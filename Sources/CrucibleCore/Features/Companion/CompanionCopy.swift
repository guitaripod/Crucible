import Foundation

/// The words Crucible Server's screens use on iPhone, iPad and Apple TV.
package enum CompanionCopy {
    package static let title = String(localized: "Crucible Server", comment: "Name of the optional companion that runs on the computer with Plex")
    package static let pitch = String(
        localized: "Free and optional. It runs on the computer with Plex and writes a Previously On before you press play, from your own episodes, on your own hardware.",
        comment: "What Crucible Server does, shown before it is set up"
    )
    package static let steps = String(
        localized: "On the computer with Plex, install Crucible Server and run crucible-server setup. Then scan the code it shows with the Camera, or enter the code here.",
        comment: "How to set up Crucible Server"
    )
    package static let notSetUp = String(localized: "Not Set Up", comment: "Crucible Server status before pairing")
    package static let enterCode = String(localized: "Enter Pairing Code", comment: "Button that pairs with Crucible Server from a typed code")
    package static let codePlaceholder = String(localized: "KQ7M-2XRD-…", comment: "Placeholder of the pairing code field; keep the letters as they are")
    package static let pair = String(localized: "Pair", comment: "Button that pairs this device with Crucible Server")
    package static let pairing = String(localized: "Pairing…", comment: "Shown while pairing with Crucible Server")
    package static let unpair = String(localized: "Unpair This Device", comment: "Button that forgets the pairing with Crucible Server")
    package static let unpairMessage = String(localized: "Previously On stops until you pair again.", comment: "Confirmation message for unpairing Crucible Server")
    package static let howToInstall = String(localized: "How to Install", comment: "Opens Crucible Server's install instructions")
    package static let installURL = URL(string: "https://github.com/guitaripod/Crucible/tree/master/server#readme")!
    package static let checking = String(localized: "Checking…", comment: "Crucible Server status while the app asks it")
    package static let previouslyOn = String(localized: "Previously On", comment: "Menu item and button that shows a recap of the episodes watched so far")
    package static let writing = String(localized: "Writing your Previously On…", comment: "Shown while Crucible Server writes a recap")

    package static func paired(_ name: String) -> String {
        String(localized: "Paired with \(name)", comment: "Crucible Server status, e.g. Paired with arch")
    }

    package static func pairQuestion(_ name: String) -> String {
        String(localized: "Pair with Crucible Server on \(name)?", comment: "Confirmation before pairing from a scanned code, e.g. Pair with Crucible Server on arch?")
    }

    package static func ready(model: String?) -> String {
        guard let model else { return String(localized: "Ready · skips only, no model yet", comment: "Crucible Server status when it has no model") }
        return String(localized: "Ready · \(model)", comment: "Crucible Server status with its model, e.g. Ready · gemma4-26b")
    }

    package static func modelSilent(_ model: String) -> String {
        String(localized: "\(model) isn't answering. Check the model server on the computer with Plex.", comment: "Crucible Server status when its model does not answer")
    }

    package static func previouslyOnTitle(_ show: String) -> String {
        String(localized: "Previously on \(show)", comment: "Title of a recap, e.g. Previously on Dragon Ball Super")
    }

    /// "From S1 · E3 to S1 · E5, written on arch", or the one episode when there was only one.
    package static func basis(_ recap: CompanionRecap, server: String) -> String {
        guard let first = recap.basedOn.first, let last = recap.basedOn.last else { return String(localized: "Written on \(server)", comment: "Where a recap was written, e.g. Written on arch") }
        if first == last { return String(localized: "From \(first), written on \(server)", comment: "What a recap draws on, e.g. From S1 · E5, written on arch") }
        return String(localized: "From \(first) to \(last), written on \(server)", comment: "What a recap draws on, e.g. From S1 · E3 to S1 · E5, written on arch")
    }
}

/// Asking the paired server for a Previously On of a show, from what this person has watched.
package enum PreviouslyOnRequest {
    /// Whether the show page should offer it: a server is paired and something before the next episode was watched.
    package static func isAvailable(_ model: ShowDetailModel) -> Bool {
        CompanionStore.current() != nil && !finished(model).isEmpty
    }

    private static func finished(_ model: ShowDetailModel) -> [String] {
        PreviouslyOn.finished(in: model.allEpisodes.isEmpty ? model.episodes : model.allEpisodes, before: model.upNext?.episode)
    }

    package static func recap(_ model: ShowDetailModel) async throws(CompanionError) -> (CompanionRecap, server: String) {
        guard let server = CompanionStore.current(), let token = ServerBootstrap.connection()?.authToken else { throw .notPaired }
        do {
            let recap = try await CompanionClient(server: server, plexToken: token).recap(finished: finished(model))
            return (recap, server.name)
        } catch {
            if error == .notPaired { CompanionStore.forget() }
            throw error
        }
    }

    /// Pairs from an invite as this device, for the Plex server Crucible is connected to, and keeps the pairing.
    package static func pair(_ invite: CompanionInvite, deviceName: String, platform: String) async throws(CompanionError) -> CompanionServer {
        let server = try await CompanionPairing.pair(invite, deviceName: deviceName, platform: platform, machineIdentifier: ServerBootstrap.connection()?.machineIdentifier)
        CompanionStore.save(server)
        return server
    }

    /// An invite from a typed code, tried where Crucible Server runs beside the Plex server Crucible uses.
    package static func invite(code: String) -> CompanionInvite? {
        guard let host = CompanionPairing.hostBesidePlex(ServerBootstrap.connection()?.serverURI) else { return nil }
        return CompanionInvite(code: code, hosts: [host])
    }
}

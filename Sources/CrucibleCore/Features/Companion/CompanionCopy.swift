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
    package static let stepsTV = String(localized: "On the computer with Plex, install Crucible Server and run crucible-server setup, then enter the code it shows here.", comment: "How to set up Crucible Server, on Apple TV")
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

    package static let pairWithIPhone = String(localized: "Pair with iPhone", comment: "Apple TV button that pairs with Crucible Server through a nearby paired iPhone")
    package static let showCode = String(localized: "Show Code for iPhone", comment: "Apple TV button that shows a QR code for a paired iPhone to scan")
    package static let codeSteps = String(
        localized: "On an iPhone or iPad already paired with Crucible Server, scan this code with the Camera. This Apple TV finishes pairing on its own.",
        comment: "Shown beside the QR code an Apple TV shows for pairing"
    )
    package static let waitingForIPhone = String(localized: "Waiting for your iPhone…", comment: "Shown on Apple TV while it waits to be paired through an iPhone")
    package static let declined = String(localized: "The iPhone didn't allow pairing.", comment: "Apple TV message when the iPhone declines")
    package static let pairThisIPhoneFirst = String(localized: "Pair this iPhone with Crucible Server first, then try again from the Apple TV.", comment: "iPhone message when an Apple TV asks to pair but the iPhone is not paired")
    package static let handOffEnded = String(localized: "The iPhone stopped answering before it handed over a pairing. Try again.", comment: "Apple TV message when the link to the iPhone ends during pairing")
    package static let addWarning = String(localized: "Allow only a code your own Apple TV is showing right now. The device that made it can use Crucible Server like this iPhone.", comment: "Warning under the question whether to add an Apple TV to Crucible Server")
    package static let tvCodeExpired = String(localized: "That Apple TV code has expired. Show a new one on the Apple TV, then scan it again.", comment: "iPhone message when the scanned Apple TV code is too old")
    package static let codeExpired = String(localized: "This code has expired. Go back and show a new one.", comment: "Apple TV message when its pairing code stopped working")
    package static let allow = String(localized: "Allow", comment: "Button that lets a nearby Apple TV pair through this iPhone")
    package static let dontAllow = String(localized: "Don't Allow", comment: "Button that refuses to let a nearby Apple TV pair through this iPhone")
    package static let addAppleTV = String(
        localized: "To add an Apple TV, choose Pair with iPhone on the TV, or scan the code it shows with the Camera.",
        comment: "Footer under Crucible Server settings on iPhone when paired"
    )

    /// "Pair Living Room with Crucible Server on arch?", asked on the iPhone when a nearby Apple TV asks through it.
    package static func handOffQuestion(device: String, server: String) -> String {
        String(localized: "Pair \(device) with Crucible Server on \(server)?", comment: "Question on iPhone when a nearby Apple TV asks to pair, e.g. Pair Living Room with Crucible Server on arch?")
    }

    /// "Add Living Room to Crucible Server on arch?", asked after scanning an Apple TV's code.
    package static func addQuestion(device: String, server: String) -> String {
        String(localized: "Add \(device) to Crucible Server on \(server)?", comment: "Question on iPhone after scanning an Apple TV's pairing code, e.g. Add Living Room to Crucible Server on arch?")
    }

    package static func added(_ device: String) -> String {
        String(localized: "\(device) is finishing pairing.", comment: "Confirmation on iPhone after handing a pairing to an Apple TV, e.g. Living Room is finishing pairing.")
    }

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
    /// `handedOn` marks an invite a paired iPhone handed over, whose secret the server admits by the person's Plex token.
    package static func pair(_ invite: CompanionInvite, deviceName: String, platform: String, handedOn: Bool = false) async throws(CompanionError) -> CompanionServer {
        let connection = ServerBootstrap.connection()
        let server = try await CompanionPairing.pair(invite, deviceName: deviceName, platform: platform, machineIdentifier: connection?.machineIdentifier, plexToken: handedOn ? connection?.authToken : nil)
        CompanionStore.save(server)
        return server
    }

    /// The paired server's client, as the person signed in to Plex on this device.
    package static func client() -> CompanionClient? {
        guard let server = CompanionStore.current(), let token = ServerBootstrap.connection()?.authToken else { return nil }
        return CompanionClient(server: server, plexToken: token)
    }

    /// Where an Apple TV looks for Crucible Server before it knows one: beside the Plex server it uses, when that is on
    /// the home network or tailnet, so a handed-on pairing and the Plex token it carries go nowhere else.
    package static func hostsBesidePlex() -> [String] {
        CompanionPairing.hostBesidePlex(ServerBootstrap.connection()?.serverURI).map { [$0] }?.filter { CompanionInvite.isNearby($0, tailnetNames: true) } ?? []
    }

    /// The pairing a nearby iPhone handed over, tried only beside the Plex server this Apple TV uses and only with the
    /// certificate the iPhone pinned, so a device that is not the person's iPhone cannot point it at another computer.
    package static func besidePlex(_ invite: CompanionInvite) -> CompanionInvite? {
        let hosts = hostsBesidePlex()
        guard invite.fingerprint != nil, !hosts.isEmpty else { return nil }
        return CompanionInvite(name: invite.name, hosts: hosts, secret: invite.secret, fingerprint: invite.fingerprint)
    }

    /// Pairs with the secret this Apple TV shows once a paired iPhone hands it to the server, keeping the pairing.
    package static func waitForHandOff(_ invite: CompanionInvite, deviceName: String, until deadline: Date) async throws(CompanionError) -> CompanionServer {
        let connection = ServerBootstrap.connection()
        let server = try await CompanionPairing.waitForHandOff(invite, deviceName: deviceName, platform: "tvos", machineIdentifier: connection?.machineIdentifier, plexToken: connection?.authToken, until: deadline)
        CompanionStore.save(server)
        return server
    }

    /// An invite from a typed code, tried where Crucible Server runs beside the Plex server Crucible uses.
    package static func invite(code: String) -> CompanionInvite? {
        guard let host = CompanionPairing.hostBesidePlex(ServerBootstrap.connection()?.serverURI) else { return nil }
        return CompanionInvite(code: code, hosts: [host])
    }
}

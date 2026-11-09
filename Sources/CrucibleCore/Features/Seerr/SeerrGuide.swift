import Foundation

/// Where the Plex server runs, which decides how Seerr and Tailscale are installed next to it.
package enum SeerrHost: String, CaseIterable, Sendable {
    case docker
    case unraid
    case synology
    case truenas
    case windows
    case mac

    package var title: String {
        switch self {
        case .docker: return String(localized: "Linux with Docker", comment: "Seerr guide: where Plex runs")
        case .unraid: return "Unraid"
        case .synology: return "Synology"
        case .truenas: return "TrueNAS"
        case .windows: return "Windows"
        case .mac: return "Mac"
        }
    }

    /// The likeliest host for the operating system Plex reports at its root; Linux covers NAS systems too, so the viewer
    /// can still pick theirs.
    package static func guess(plexPlatform: String?) -> SeerrHost {
        switch plexPlatform?.lowercased() {
        case "windows": return .windows
        case "macosx", "macos", "mac os x", "osx": return .mac
        default: return .docker
        }
    }
}

/// One line of a guide step: words, a command to copy, or a link to open.
package enum SeerrGuideLine: Hashable, Sendable {
    case text(String)
    case command(String)
    case link(String, URL)
}

/// The steps that take someone from no Seerr to requesting from Crucible anywhere: install Seerr next to Plex, finish its
/// setup, hand requests to Radarr and Sonarr, let Plex users in, and reach it away from home over Tailscale. The words are
/// shared by iPhone, iPad, Apple TV and the web guide at `webGuide`.
package enum SeerrGuide {
    package static let webGuide = URL(string: "https://midgarcorp.cc/crucible/seerr/")!
    package static let image = "ghcr.io/seerr-team/seerr:latest"
    package static let tailscaleDownload = URL(string: "https://tailscale.com/download")!
    package static let dockerDesktop = URL(string: "https://www.docker.com/products/docker-desktop/")!
    package static let synoCommunity = "https://packages.synocommunity.com"
    package static let tailscaleSynology = URL(string: "https://tailscale.com/docs/integrations/synology")!
    package static let seerrDocs = URL(string: "https://docs.seerr.dev/getting-started/")!

    package static let title = String(localized: "Set Up Seerr", comment: "Title of the Seerr setup guide")
    package static let intro = String(localized: "Seerr runs on the computer that runs Plex. These steps take about ten minutes, and Crucible checks each one as you go.", comment: "Seerr guide introduction")
    package static let hostQuestion = String(localized: "Plex Runs On", comment: "Seerr guide: picker for the system Plex runs on")
    package static let notOwner = String(localized: "Only whoever runs this Plex server can install Seerr. Send them this guide; once Seerr is running, connect here.", comment: "Seerr guide note for someone who does not own the server")
    package static let openOnComputer = String(localized: "Open This Guide on Your Computer", comment: "Seerr guide button that shares the web guide")
    package static let scanForGuide = String(localized: "Scan to open this guide on your phone or computer", comment: "Caption under the QR code of the Seerr guide on Apple TV")
    package static let scanForSeerr = String(localized: "Scan at home to open Seerr's setup", comment: "Caption under the QR code of Seerr's address on Apple TV")
    package static let copy = String(localized: "Copy", comment: "Button that copies a command in the Seerr guide")
    package static let copied = String(localized: "Copied", comment: "Shown after a command was copied")
    package static let optional = String(localized: "Optional", comment: "Seerr guide: a step that can be skipped")
    package static let otherAddress = String(localized: "For a Seerr on another computer or port", comment: "Subtitle of Enter Address in the Seerr guide")
    package static let lookThere = String(localized: "Look There", comment: "Button that makes the Seerr guide look at a typed address")

    // MARK: Steps

    package enum Step: Int, CaseIterable, Sendable {
        case install
        case setUp
        case downloads
        case people
        case away
    }

    package static func title(_ step: Step) -> String {
        switch step {
        case .install: return String(localized: "Install Seerr", comment: "Seerr guide step title")
        case .setUp: return String(localized: "Finish Seerr's Setup", comment: "Seerr guide step title")
        case .downloads: return String(localized: "Hand Requests to Radarr and Sonarr", comment: "Seerr guide step title")
        case .people: return String(localized: "Let Your Plex Users In", comment: "Seerr guide step title")
        case .away: return String(localized: "Request Away From Home", comment: "Seerr guide step title")
        }
    }

    /// The step's lines for a server that runs on `host`. `home` is the server's address on the home network, `server` its
    /// name, `timeZone` the zone the Docker command sets (this device's, which the text says to change if the server's differs).
    package static func lines(_ step: Step, host: SeerrHost, home: String?, server: String, timeZone: String = TimeZone.current.identifier, platformName: String) -> [SeerrGuideLine] {
        switch step {
        case .install: return install(host: host, timeZone: timeZone)
        case .setUp: return setUp(home: home, server: server)
        case .downloads: return downloads(home: home)
        case .people: return people
        case .away: return away(host: host, platformName: platformName)
        }
    }

    package static let placeholderAddress = String(localized: "your-plex-computer", comment: "Placeholder for the Plex computer's address in the Seerr guide")
    package static let migrationGuide = URL(string: "https://docs.seerr.dev/migration-guide/")!
    package static let dockerEngine = URL(string: "https://docs.docker.com/engine/install/")!
    package static let tailscaleTrueNAS = URL(string: "https://tailscale.com/docs/integrations/truenas")!

    private static func dockerRun(volume: String, timeZone: String, sudo: Bool) -> String {
        (sudo ? "sudo " : "") + "docker run -d --name seerr --init --restart unless-stopped -p 5055:5055 -e TZ=\(timeZone) -v \(volume):/app/config \(image)"
    }

    private static func timeZoneNote(_ timeZone: String) -> SeerrGuideLine {
        .text(String(localized: "TZ is this device's time zone, \(timeZone). If the Plex computer is in another one, change it to that zone's name, such as Europe/London.", comment: "Seerr guide: the time zone in the Docker command"))
    }

    private static func install(host: SeerrHost, timeZone: String) -> [SeerrGuideLine] {
        var lines: [SeerrGuideLine]
        switch host {
        case .docker:
            lines = [
                .text(String(localized: "On the computer that runs Plex, open a terminal and run these two commands. The first makes the folder Seerr keeps its settings in; the second starts Seerr and keeps it running after restarts.", comment: "Seerr guide: Docker install")),
                .command("mkdir -p ~/seerr/config && sudo chown -R 1000:1000 ~/seerr/config"),
                .command(dockerRun(volume: "~/seerr/config", timeZone: timeZone, sudo: true)),
                timeZoneNote(timeZone),
                .text(String(localized: "No Docker on that computer yet? Install Docker Engine first:", comment: "Seerr guide: Docker missing on Linux")),
                .link(String(localized: "Install Docker Engine", comment: "Seerr guide link"), dockerEngine),
            ]
        case .unraid:
            lines = [
                .text(String(localized: "In Unraid, open Apps, search for Seerr and install it. In its template, switch from Basic View to Advanced View at the top right and check that Extra Parameters includes --init. Keep port 5055.", comment: "Seerr guide: Unraid install")),
            ]
        case .synology:
            lines = [
                .text(String(localized: "Seerr comes from SynoCommunity and needs DSM 7.2 or later. In Package Center open Settings, then Package Sources, and add SynoCommunity with this address. Then search Package Center for Seerr and install it.", comment: "Seerr guide: Synology install")),
                .command(synoCommunity),
            ]
        case .truenas:
            lines = [
                .text(String(localized: "In TrueNAS, open Apps, choose Discover Apps, search for Seerr and install it. Keep its web port at 5055, which is where Crucible looks.", comment: "Seerr guide: TrueNAS install")),
            ]
        case .windows:
            lines = [
                .text(String(localized: "Install Docker Desktop, which also sets up WSL 2, and start it. Then run these two commands in PowerShell:", comment: "Seerr guide: Windows install")),
                .link(String(localized: "Get Docker Desktop", comment: "Seerr guide link"), dockerDesktop),
                .command("docker volume create seerr-data"),
                .command(dockerRun(volume: "seerr-data", timeZone: timeZone, sudo: false)),
                timeZoneNote(timeZone),
            ]
        case .mac:
            lines = [
                .text(String(localized: "Install Docker Desktop and start it. Then run these two commands in Terminal:", comment: "Seerr guide: Mac install")),
                .link(String(localized: "Get Docker Desktop", comment: "Seerr guide link"), dockerDesktop),
                .command("docker volume create seerr-data"),
                .command(dockerRun(volume: "seerr-data", timeZone: timeZone, sudo: false)),
                timeZoneNote(timeZone),
            ]
        }
        lines += [
            .text(String(localized: "Already run Overseerr or Jellyseerr for Plex? Crucible works with it as it is, so skip ahead. To move to Seerr, their successor, back up its config folder first and follow Seerr's migration guide.", comment: "Seerr guide: existing Overseerr or Jellyseerr")),
            .link(String(localized: "Seerr's Migration Guide", comment: "Seerr guide link"), migrationGuide),
        ]
        return lines
    }

    /// Seerr's own setup, step by step as its screens name them (Choose Server Type, Sign In, Configure Media Server,
    /// Configure Services).
    private static func setUp(home: String?, server: String) -> [SeerrGuideLine] {
        let address = "http://\(home ?? placeholderAddress):\(SeerrDiscovery.defaultPort)"
        var lines: [SeerrGuideLine] = [
            .text(String(localized: "On any device at home, open Seerr in a browser:", comment: "Seerr guide: open Seerr")),
        ]
        if let url = URL(string: address), home != nil {
            lines.append(.link(address, url))
        } else {
            lines.append(.command(address))
        }
        let wizard = [
            String(localized: "Choose Server Type: choose Configure Plex.", comment: "Seerr guide: setup wizard step"),
            String(localized: "Sign In with the Plex account that owns \(server).", comment: "Seerr guide: setup wizard step, with the server's name"),
            String(localized: "Configure Media Server: press the button beside Server to load your servers, choose \(server), press Sync Libraries, turn on the libraries to request into, then Continue.", comment: "Seerr guide: setup wizard step, with the server's name"),
            String(localized: "Configure Services: add Radarr and Sonarr now or later, then Finish Setup.", comment: "Seerr guide: setup wizard step"),
        ]
        lines.append(.text(String(localized: "Seerr's setup then asks you to:", comment: "Seerr guide: before the setup wizard steps")))
        lines.append(.text(wizard.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")))
        return lines
    }

    private static func downloads(home: String?) -> [SeerrGuideLine] {
        let example = home.flatMap { $0 == "localhost" || $0.hasPrefix("127.") ? nil : $0 } ?? "192.168.1.20"
        return [
            .text(String(localized: "Seerr keeps track of requests; Radarr (movies) and Sonarr (shows) take the approved ones and add the titles to your library. Without them requests still wait in Seerr for you to add the titles yourself.", comment: "Seerr guide: what Radarr and Sonarr do")),
            .text(String(localized: "In Seerr open Settings, then Services, and choose Add Radarr Server and Add Sonarr Server. For each, enter the computer it runs on by its network address, such as \(example), never localhost (Seerr runs in its own container), its port (7878 for Radarr, 8989 for Sonarr unless you changed them) and its API key, which Radarr and Sonarr show under Settings, General, Security.", comment: "Seerr guide: adding Radarr and Sonarr, with an example address")),
            .text(String(localized: "Turn on Default Server for each, or requests have nowhere to go.", comment: "Seerr guide: default server")),
        ]
    }

    private static let people: [SeerrGuideLine] = [
        .text(String(localized: "In Seerr open Settings, then Users. Keep Enable Plex Sign-In and Enable New Plex Sign-In on, so everyone you share Plex with can sign in from Crucible with their own account.", comment: "Seerr guide: user sign-in settings")),
        .text(String(localized: "Under Default Permissions, Request lets them ask for titles, and Auto-Approve sends their requests on without waiting for you.", comment: "Seerr guide: default permissions")),
    ]

    private static func away(host: SeerrHost, platformName: String) -> [SeerrGuideLine] {
        var lines: [SeerrGuideLine] = [
            .text(String(localized: "At home Crucible reaches Seerr over your home network. Everywhere else it uses Tailscale, a private network between your own devices that's free for personal use: nothing opens on your router and Seerr stays off the internet.", comment: "Seerr guide: why Tailscale")),
            .text(String(localized: "On the Plex computer:", comment: "Seerr guide: Tailscale on the server")),
        ]
        switch host {
        case .docker:
            lines += [
                .command("curl -fsSL https://tailscale.com/install.sh | sh"),
                .command("sudo tailscale up"),
                .text(String(localized: "Open the link it prints and sign in.", comment: "Seerr guide: Tailscale sign-in on Linux")),
            ]
        case .unraid:
            lines.append(.text(String(localized: "Open Apps, install Tailscale (Plugin), then sign in under Settings, Network Services, Tailscale.", comment: "Seerr guide: Tailscale on Unraid")))
        case .synology:
            lines += [
                .text(String(localized: "Install Tailscale's own package, not the older one in Package Center. Then in Control Panel, Task Scheduler, create a Triggered Task that runs as root at boot-up with this command, so Tailscale keeps working after a restart:", comment: "Seerr guide: Tailscale on Synology")),
                .command("/var/packages/Tailscale/target/bin/tailscale configure-host; synosystemctl restart pkgctl-Tailscale.service"),
                .link(String(localized: "Tailscale on Synology", comment: "Seerr guide link"), tailscaleSynology),
            ]
        case .truenas:
            lines += [
                .text(String(localized: "In Tailscale's admin console, under Settings, Keys, generate an auth key. Then in TrueNAS open Apps, choose Discover Apps, install Tailscale, enter the auth key and a hostname, and tick Userspace.", comment: "Seerr guide: Tailscale on TrueNAS")),
                .link(String(localized: "Tailscale on TrueNAS", comment: "Seerr guide link"), tailscaleTrueNAS),
            ]
        case .windows, .mac:
            lines += [
                .text(String(localized: "Install Tailscale and sign in.", comment: "Seerr guide: Tailscale on Windows or Mac")),
                .link(String(localized: "Get Tailscale", comment: "Seerr guide link"), tailscaleDownload),
            ]
        }
        lines.append(.text(String(localized: "On this \(platformName): install Tailscale from the App Store and sign in with the same account. Crucible then reaches Seerr through it whenever you're away from home.", comment: "Seerr guide: Tailscale on this device, with the device name")))
        return lines
    }

    /// One or two lines per step for Apple TV, where the full steps and commands are a QR code away.
    package static func summary(_ step: Step, host: SeerrHost, home: String?, server: String) -> String {
        switch step {
        case .install:
            switch host {
            case .docker: return String(localized: "On the Plex computer, run the Docker command from the guide.", comment: "Seerr guide summary on Apple TV: Docker")
            case .unraid: return String(localized: "In Unraid: Apps, search for Seerr, Install. Keep port 5055.", comment: "Seerr guide summary on Apple TV: Unraid")
            case .synology: return String(localized: "In Package Center, add the SynoCommunity source, then install Seerr.", comment: "Seerr guide summary on Apple TV: Synology")
            case .truenas: return String(localized: "In TrueNAS: Apps, Discover Apps, Seerr, Install. Keep port 5055.", comment: "Seerr guide summary on Apple TV: TrueNAS")
            case .windows: return String(localized: "Install Docker Desktop, then run the command from the guide in PowerShell.", comment: "Seerr guide summary on Apple TV: Windows")
            case .mac: return String(localized: "Install Docker Desktop, then run the command from the guide in Terminal.", comment: "Seerr guide summary on Apple TV: Mac")
            }
        case .setUp:
            let address = "\(home ?? placeholderAddress):\(SeerrDiscovery.defaultPort)"
            return String(localized: "Open \(address) at home: Configure Plex, sign in, load and choose \(server), Sync Libraries, turn one on, Continue, Finish Setup.", comment: "Seerr guide summary on Apple TV: setup, with the address and server name")
        case .downloads:
            return String(localized: "Optional: in Seerr's Settings, Services, add Radarr and Sonarr by network address and turn on Default Server.", comment: "Seerr guide summary on Apple TV: Radarr and Sonarr")
        case .people:
            return String(localized: "In Seerr's Settings, Users, keep Plex sign-in and new Plex sign-in on.", comment: "Seerr guide summary on Apple TV: users")
        case .away:
            return String(localized: "Install Tailscale on the Plex computer and on this Apple TV, signed in to one account.", comment: "Seerr guide summary on Apple TV: Tailscale")
        }
    }

    package static let statusFound = String(localized: "Running", comment: "Seerr guide status value: Seerr answers")
    package static let statusNotYet = String(localized: "Not Yet", comment: "Seerr guide status value: not done yet")
    package static let statusDone = String(localized: "Done", comment: "Seerr guide status value: done")
    package static let statusUnfinished = String(localized: "Unfinished", comment: "Seerr guide status value: setup not finished")
    package static let statusWrongServer = String(localized: "Jellyfin or Emby", comment: "Seerr guide status value: Seerr set up for another media server")
    package static let statusOn = String(localized: "On", comment: "Seerr guide status value: Tailscale on")
    package static let statusOff = String(localized: "Off", comment: "Seerr guide status value: Tailscale off")

    // MARK: Troubleshooting

    package static let troubleTitle = String(localized: "If Something's Not Working", comment: "Seerr guide troubleshooting title")

    package static func trouble(home: String?) -> [SeerrGuideLine] {
        let address = "http://\(home ?? placeholderAddress):\(SeerrDiscovery.defaultPort)"
        return [
            .text(String(localized: "Seerr doesn't show up: on the Plex computer, open http://localhost:5055. If nothing opens, Seerr isn't running; with Docker, sudo docker ps and sudo docker logs seerr say why. If it opens there but \(address) doesn't open on your phone, check the phone is on the home network, and on Windows set that network to Private and allow Docker Desktop through the firewall.", comment: "Seerr guide troubleshooting: Seerr not found, with its address")),
            .text(String(localized: "Docker says the name seerr is already in use: an earlier try is still there. Remove it with sudo docker rm -f seerr and run the command again.", comment: "Seerr guide troubleshooting: container name in use")),
            .text(String(localized: "Seerr runs on another computer or port: choose Enter Address and type it, such as 192.168.1.50:5055 or requests.example.com.", comment: "Seerr guide troubleshooting: other address")),
            .text(String(localized: "Connecting fails after you turned on Enable CSRF Protection: that setting makes Seerr refuse plain HTTP, which is how Crucible talks to it at home, so its own pages stop opening too. Stop Seerr, set csrfProtection to false in settings.json in its config folder, and start it again.", comment: "Seerr guide troubleshooting: CSRF")),
            .text(String(localized: "Seerr is set up for Jellyfin or Emby: Crucible needs a Seerr set up for Plex.", comment: "Seerr guide troubleshooting: wrong media server")),
            .link(String(localized: "Seerr's Own Documentation", comment: "Seerr guide link"), seerrDocs),
        ]
    }

    // MARK: Status

    package static let looking = String(localized: "Looking for Seerr…", comment: "Seerr guide status while checking")
    package static func notYet(_ address: String) -> String {
        String(localized: "Not running at \(address) yet. Crucible keeps checking.", comment: "Seerr guide status: Seerr not found yet, with the address checked")
    }
    package static func running(_ address: String) -> String {
        String(localized: "Seerr is running at \(address)", comment: "Seerr guide status: Seerr found")
    }
    package static let needsSetup = String(localized: "Seerr is running; its setup isn't finished yet", comment: "Seerr guide status: Seerr found but not set up")
    package static let setUpDone = String(localized: "Seerr's setup is finished", comment: "Seerr guide status: setup done")
    package static let notPlex = String(localized: "This Seerr is set up for Jellyfin or Emby, not Plex", comment: "Seerr guide status: wrong media server")
    package static func deviceOnTailnet(_ device: String) -> String {
        String(localized: "This \(device) is on Tailscale", comment: "Seerr guide status: device on Tailscale")
    }
    package static func deviceOffTailnet(_ device: String) -> String {
        String(localized: "Tailscale is off on this \(device)", comment: "Seerr guide status: device not on Tailscale")
    }
    package static func serverOnTailnet(_ address: String) -> String {
        String(localized: "Plex computer found on Tailscale at \(address)", comment: "Seerr guide status: server reachable over Tailscale")
    }
    package static let serverOffTailnet = String(localized: "Plex computer not found on Tailscale yet", comment: "Seerr guide status: server not on Tailscale")
    package static let readyToConnect = String(localized: "Seerr is ready. Connect with your Plex account.", comment: "Seerr guide status: ready to connect")
}

/// What the guide sees right now: whether Seerr answers next to the server and is set up for Plex, and whether this
/// device and the server are on Tailscale. It looks again every few seconds while a guide screen is open.
@MainActor
package final class SeerrSetupWatcher {
    package enum Seerr: Equatable, Sendable {
        case looking
        case notFound
        case needsSetup(URL)
        case notPlex(URL)
        case ready(URL, SeerrPublicSettings)

        package var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    package static let interval: Duration = .seconds(5)

    package private(set) var seerr: Seerr = .looking
    package private(set) var deviceOnTailnet = TailnetPresence.isConnected
    package private(set) var host: SeerrHost = .docker
    private var hostChosen = false
    private var hostGuessed = false
    private var typed: [URL] = []
    private var loop: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private let api: APIClient
    private let client: SeerrClient

    package init(api: APIClient, client: SeerrClient = .shared) {
        self.api = api
        self.client = client
    }

    /// The server's routes, the one in use first.
    package var serverRoutes: [URL] {
        let routes = SeerrAccount.liveServerRoutes()
        return [routes.inUse].compactMap { $0 } + routes.routes.filter { $0 != routes.inUse }
    }

    /// The server's address on the home network, shown in the guide and opened for Seerr's setup.
    package var homeHost: String? {
        SeerrRoutes.hosts(of: serverRoutes).first { Self.kind(of: $0) == .local }
    }

    /// The server's tailnet address, once Crucible found it.
    package var tailnetHost: String? {
        SeerrRoutes.hosts(of: serverRoutes).first { Self.kind(of: $0) == .tailscale }
    }

    private static func kind(of host: String) -> ConnectionKind? {
        URL(string: "http://\(host)").map(ConnectionRoute.kind(of:))
    }

    package var serverName: String {
        ServerBootstrap.connection()?.serverName ?? "Plex"
    }

    /// Where Seerr's setup opens: the home address, or the address Seerr was found at.
    package var setupURL: URL? {
        switch seerr {
        case .needsSetup(let url), .notPlex(let url), .ready(let url, _): return url
        case .looking, .notFound: return homeHost.flatMap { URL(string: "http://\($0):\(SeerrDiscovery.defaultPort)") }
        }
    }

    package func choose(_ host: SeerrHost) {
        self.host = host
        hostChosen = true
        onChange?()
    }

    /// Looks at what the viewer typed too, for a Seerr on another computer or port, and looks again now.
    package func add(typed text: String) {
        let addresses = SeerrDiscovery.addresses(from: text).filter { !typed.contains($0) }
        guard !addresses.isEmpty else { return }
        typed = addresses + typed
        Task { await look() }
    }

    /// Starts looking, calling `onChange` on the main actor after each look that changed something.
    package func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard loop == nil else { return }
        if !hostGuessed { Task { [weak self] in await self?.guessHost() } }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await look()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    package func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Picks the host from the system Plex reports, once, unless the viewer already chose one.
    private func guessHost() async {
        guard !hostGuessed else { return }
        hostGuessed = true
        let root: PlexServerRoot? = try? await api.request(.serverRoot)
        guard !hostChosen, let platform = root?.MediaContainer.platform else { return }
        host = SeerrHost.guess(plexPlatform: platform)
        onChange?()
    }

    private func look() async {
        var addresses = typed + [SeerrAccount.shared.knownAddress, SeerrConfig.standInAddress].compactMap { $0 }
        addresses += SeerrDiscovery.candidates(serverRoutes: serverRoutes).filter { !addresses.contains($0) }
        let found = await SeerrDiscovery.survey(addresses, client: client)
        let onTailnet = TailnetPresence.isConnected
        guard found != seerr || onTailnet != deviceOnTailnet else { return }
        seerr = found
        deviceOnTailnet = onTailnet
        onChange?()
    }
}

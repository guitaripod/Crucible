import Foundation

/// The demo account's Plex Home, so every kind of viewer can be tried without a real Home: the owner, Sam (a member with an account
/// of their own and the PIN 1234) and Kids (a managed profile restricted to family titles). Each profile has a library of its own
/// behind the same server, the way a real server keeps each viewer's watch state, and only the owner owns the server.
enum DemoHome {
    struct Member: Sendable, Hashable {
        let uuid: String
        let title: String
        let isAdmin: Bool
        let pin: String?
        let isRestricted: Bool

        var isProtected: Bool { pin != nil }

        /// The plex.tv token the member's switch hands out; the owner's is the account's own.
        var plexTVToken: String { isAdmin ? DemoPlexTV.token : Self.profileTokenPrefix + uuid }

        /// The token the server takes from the member, as the member's own list of servers gives it.
        var serverToken: String { isAdmin ? DemoHome.ownerServerToken : Self.serverTokenPrefix + uuid }

        fileprivate static let profileTokenPrefix = "demo-profile-"
        fileprivate static let serverTokenPrefix = "demo-server-"
    }

    static let ownerServerToken = "demo-server-token"

    static let owner = Member(uuid: "d3a41e7b5c9f4a2e", title: "Demo", isAdmin: true, pin: nil, isRestricted: false)
    static let sam = Member(uuid: "5a3e9c1f7b2d4e60", title: "Sam", isAdmin: false, pin: "1234", isRestricted: false)
    static let kids = Member(uuid: "8c2f6a4d1e9b3c75", title: "Kids", isAdmin: false, pin: nil, isRestricted: true)

    static let members = [owner, sam, kids]

    /// Age ratings a restricted profile may see.
    static let familyRatings: Set<String> = ["G", "PG", "TV-Y", "TV-Y7", "TV-G", "TV-PG"]

    /// Whoever a request's token belongs to. A request without a token, or with one the Home does not know, is the owner's, as the
    /// artwork and media requests of the app's image and video loaders are.
    static func member(forToken token: String?) -> Member {
        guard let token else { return owner }
        for prefix in [Member.profileTokenPrefix, Member.serverTokenPrefix] where token.hasPrefix(prefix) {
            let uuid = String(token.dropFirst(prefix.count))
            if let member = members.first(where: { $0.uuid == uuid && !$0.isAdmin }) { return member }
        }
        return owner
    }

    static func member(uuid: String) -> Member? {
        members.first { $0.uuid == uuid }
    }

    /// Where a member's watch state is kept: the owner's in the demo's own file, everyone else's beside it.
    static func stateFileURL(for member: Member, ownerFile: URL?) -> URL? {
        guard !member.isAdmin, let ownerFile else { return ownerFile }
        return ownerFile.deletingLastPathComponent().appendingPathComponent("state-\(member.uuid).json")
    }
}

/// One library per member of the Home, each started the first time someone asks for it, and flushed together when the demo stops.
actor DemoHomeLibraries {
    private let catalogue: URL
    private let ownerStateFile: URL?
    private var libraries: [String: Task<DemoLibrary, Error>] = [:]

    let owner: DemoLibrary

    init(catalogue: URL, ownerStateFile: URL?) async throws {
        self.catalogue = catalogue
        self.ownerStateFile = ownerStateFile
        owner = try await DemoLibrary(catalogURL: catalogue, store: DemoStateStore(fileURL: ownerStateFile))
    }

    /// The member's library, started once however many requests ask for it at the same moment.
    func library(for member: DemoHome.Member) async throws -> DemoLibrary {
        if member.isAdmin { return owner }
        if let loading = libraries[member.uuid] { return try await loading.value }
        let catalogue = catalogue
        let file = DemoHome.stateFileURL(for: member, ownerFile: ownerStateFile)
        let loading = Task { try await DemoLibrary(catalogURL: catalogue, store: DemoStateStore(fileURL: file), viewer: member) }
        libraries[member.uuid] = loading
        do {
            return try await loading.value
        } catch {
            libraries[member.uuid] = nil
            throw error
        }
    }

    func flush() async {
        await owner.flush()
        for loading in libraries.values {
            if let library = try? await loading.value { await library.flush() }
        }
    }
}

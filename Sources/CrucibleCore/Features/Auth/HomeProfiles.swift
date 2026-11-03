import Foundation
import MidgarCore

/// One member of the account's Plex Home: the owner, someone with an account of their own, or a managed profile (a child, a
/// guest) that has no account at all.
package struct HomeProfile: Sendable, Hashable, Identifiable, Codable {
    package let id: String
    package let title: String
    package let thumb: String?
    package let isAdmin: Bool
    /// Switching to it asks for its PIN.
    package let isProtected: Bool
    /// A managed profile whose content the owner restricts.
    package let isRestricted: Bool

    package init(id: String, title: String, thumb: String?, isAdmin: Bool, isProtected: Bool, isRestricted: Bool) {
        self.id = id
        self.title = title
        self.thumb = thumb
        self.isAdmin = isAdmin
        self.isProtected = isProtected
        self.isRestricted = isRestricted
    }

    /// What the profile list says under its name.
    package var detail: String? {
        if isAdmin { return String(localized: "Owner", comment: "Under the Plex Home profile of the account that owns the Home") }
        if isRestricted { return String(localized: "Managed", comment: "Under a Plex Home profile whose content the owner restricts") }
        return nil
    }
}

/// The account's Plex Home and the profile watching now. The account's own sign-in is never touched: a profile's token is kept
/// under a key of its own, signing out forgets both, and going back to the account only forgets the profile's. Every profile
/// that has a PIN asks for it, the owner's too, so a child cannot switch back without it.
package enum HomeProfiles {
    package enum SwitchError: Error, LocalizedError, Equatable {
        case wrongPIN
        case notOnThisServer

        package var errorDescription: String? {
            switch self {
            case .wrongPIN:
                return String(localized: "That PIN isn’t right.", comment: "Error when the PIN of a Plex Home profile is wrong")
            case .notOnThisServer:
                return String(localized: "This profile can’t use this server. The server’s owner can share it with them in Plex.", comment: "Error when a Plex Home profile has no access to the current server")
            }
        }
    }

    private static let profileKey = "plex_home_profile"
    private static let profileTokenKey = "plex_home_profile_token"
    private static let profilePlexTVTokenKey = "plex_home_profile_plextv_token"
    private static let countKey = "plex_home_profile_count"

    /// The profile watching now; nil while the account itself is.
    package static var active: HomeProfile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(HomeProfile.self, from: data)
    }

    /// The token the server takes from the profile watching now, nil while the account itself is.
    package static var activeServerToken: String? {
        guard active != nil else { return nil }
        return KeychainHelper.load(key: profileTokenKey)
    }

    /// The profile's own plex.tv token, for its watchlist and its list of servers.
    package static var activePlexTVToken: String? {
        guard active != nil else { return nil }
        return KeychainHelper.load(key: profilePlexTVTokenKey)
    }

    /// How many profiles the Home had when last asked, so the You tab can offer Switch Profile before it asks again.
    package static var knownCount: Int {
        UserDefaults.standard.integer(forKey: countKey)
    }

    package static var title: String {
        String(localized: "Switch Profile", comment: "Row and screen title for choosing another Plex Home profile")
    }

    /// The profiles of the Home and which of them is the signed-in account. An account outside a Home has only itself, which is
    /// no choice at all, so the list is empty then.
    package static func load(accountToken: String) async throws -> (profiles: [HomeProfile], accountID: String?) {
        async let response: HomeUsersResponse = APIClient.plexTVRequest(.homeUsers, token: accountToken)
        async let account: AccountResponse? = try? APIClient.plexTVRequest(.account, token: accountToken)
        let profiles = try await response.users.compactMap(\.profile)
        let accountID = await account?.uuid
        UserDefaults.standard.set(profiles.count, forKey: countKey)
        return (profiles.count > 1 ? profiles : [], accountID)
    }

    /// Switches to `profile` on the server `machineIdentifier`: plex.tv checks the PIN and hands out the profile's token, and the
    /// profile's own list of servers gives the token the server takes from it. Choosing the signed-in account again only checks its
    /// PIN and forgets the profile. Nothing is saved unless every step worked.
    package static func switchTo(
        _ profile: HomeProfile,
        pin: String?,
        isAccount: Bool,
        accountToken: String,
        machineIdentifier: String
    ) async throws {
        let switched: SwitchResponse
        do {
            switched = try await APIClient.plexTVRequest(.switchHomeUser(uuid: profile.id, pin: pin), token: accountToken)
        } catch APIError.unauthorized where pin != nil {
            throw SwitchError.wrongPIN
        } catch APIError.httpError(let status, _) where pin != nil && (status == 403 || status == 422) {
            throw SwitchError.wrongPIN
        }
        if isAccount {
            forgetProfile()
            MidgarLog.notice("Back to the account's own profile", category: .lifecycle)
            return
        }
        guard let profileToken = switched.token else { throw APIError.decodingError("no authToken") }
        let resources: [PlexResource] = try await APIClient.plexTVRequest(.resources, token: profileToken)
        guard let server = resources.first(where: { $0.clientIdentifier == machineIdentifier }) else {
            throw SwitchError.notOnThisServer
        }
        activate(profile, serverToken: server.accessToken ?? profileToken, plexTVToken: profileToken)
        MidgarLog.notice("Switched to a Home profile (restricted=\(profile.isRestricted))", category: .lifecycle)
    }

    static func activate(_ profile: HomeProfile, serverToken: String, plexTVToken: String) {
        KeychainHelper.save(key: profileTokenKey, value: serverToken)
        KeychainHelper.save(key: profilePlexTVTokenKey, value: plexTVToken)
        UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: profileKey)
    }

    /// Back to the signed-in account. The account's own token was never replaced, so nothing else changes.
    package static func forgetProfile() {
        KeychainHelper.delete(key: profileTokenKey)
        KeychainHelper.delete(key: profilePlexTVTokenKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
    }

    /// Signing out forgets the Home along with the account.
    package static func forgetAll() {
        forgetProfile()
        UserDefaults.standard.removeObject(forKey: countKey)
    }
}

struct HomeUsersResponse: Decodable {
    let users: [HomeUser]
}

private struct AccountResponse: Decodable {
    let uuid: String?
}

private struct SwitchResponse: Decodable {
    let authToken: String?
    let authenticationToken: String?

    var token: String? { authToken ?? authenticationToken }
}

/// One `users` entry of `/api/v2/home/users`. Flags arrive as booleans or as 0 and 1.
struct HomeUser: Decodable {
    let uuid: String?
    let title: String?
    let username: String?
    let thumb: String?
    let admin: Bool
    let protected: Bool
    let restricted: Bool

    private enum Keys: String, CodingKey { case uuid, title, username, thumb, admin, protected, restricted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        username = try? container.decodeIfPresent(String.self, forKey: .username)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        admin = Self.flag(container, .admin)
        protected = Self.flag(container, .protected)
        restricted = Self.flag(container, .restricted)
    }

    private static func flag(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) -> Bool {
        if let bool = try? container.decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        return false
    }

    var profile: HomeProfile? {
        guard let uuid, !uuid.isEmpty else { return nil }
        let name = [title, username].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return HomeProfile(id: uuid, title: name ?? PlexAccountName.fallbackName, thumb: thumb, isAdmin: admin, isProtected: protected, isRestricted: restricted)
    }
}

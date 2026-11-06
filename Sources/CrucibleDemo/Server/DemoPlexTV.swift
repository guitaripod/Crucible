import Foundation

/// The plex.tv side of the demo: the PIN link flow, the account's server list (this one library), the account itself and its
/// Plex Home (`DemoHome`), whose members switch with their PIN and see the server as shared with them.
actor DemoPlexTV {
    static let token = "demo-token"
    static let pinLifetime = 900

    private struct Pin {
        let id: Int
        let code: String
        let product: String
        let clientIdentifier: String
        let createdAt: Date
        var polls = 0
    }

    private let machineIdentifier: String
    private let serverName: String
    private var pins: [Int: Pin] = [:]

    init(machineIdentifier: String, serverName: String) {
        self.machineIdentifier = machineIdentifier
        self.serverName = serverName
    }

    func createPin(strong: Bool, product: String, clientIdentifier: String) -> DemoResponse {
        let alphabet = Array(strong ? "abcdefghijklmnopqrstuvwxyz0123456789" : "ABCDEFGHJKLMNPQRSTUVWXYZ")
        let code = String((0..<(strong ? 24 : 4)).map { _ in alphabet.randomElement() ?? "A" })
        let pin = Pin(id: 1_000_000 + pins.count + 1, code: code, product: product, clientIdentifier: clientIdentifier, createdAt: Date())
        pins[pin.id] = pin
        return .json(payload(pin, token: nil), status: 201)
    }

    /// A PIN is approved from its first poll on: the demo has no one to approve it.
    func pollPin(_ id: Int) -> DemoResponse {
        guard var pin = pins[id], Date().timeIntervalSince(pin.createdAt) <= Double(Self.pinLifetime) else {
            return .json(["errors": [["code": 1020, "message": "Code not found or expired"]]], status: 404)
        }
        pin.polls += 1
        pins[id] = pin
        return .json(payload(pin, token: Self.token))
    }

    /// The servers of whoever `token` belongs to: the owner's own, or for a Home member the same server shared with them, with the
    /// token the server takes from that member.
    func resources(baseURL: String, token: String?) -> DemoResponse {
        let member = DemoHome.member(forToken: token)
        let now = Self.iso(Date())
        let uri = baseURL
        let components = URLComponents(string: baseURL)
        let server: DemoJSON = [
            "name": serverName, "product": "Plex Media Server", "productVersion": "1.41.4.9463-630c9f557", "platform": "Linux",
            "platformVersion": "6.8.0", "device": "PC", "clientIdentifier": machineIdentifier, "createdAt": "2024-03-02T10:14:09Z",
            "lastSeenAt": now, "provides": "server", "ownerId": 1, "publicAddress": "127.0.0.1", "accessToken": member.serverToken,
            "owned": member.isAdmin, "home": true, "synced": false, "relay": false, "presence": true, "httpsRequired": false,
            "publicAddressMatches": true, "dnsRebindingProtection": false, "natLoopbackSupported": false,
            "connections": [[
                "protocol": "http", "address": components?.host ?? "127.0.0.1", "port": components?.port ?? 0, "uri": uri,
                "local": true, "relay": false, "IPv6": false,
            ] as DemoJSON],
        ]
        return .json([server])
    }

    func user(token: String?) -> DemoResponse {
        let member = DemoHome.member(forToken: token)
        let id = (DemoHome.members.firstIndex(of: member) ?? 0) + 1
        let username = member.title.lowercased()
        return .json([
            "id": id, "uuid": member.uuid, "username": username, "title": member.title, "friendlyName": member.title,
            "email": "\(username)@crucible.invalid", "confirmed": true, "emailOnlyAuth": false, "hasPassword": member.isAdmin,
            "protected": member.isProtected, "restricted": member.isRestricted, "home": true, "homeAdmin": member.isAdmin,
            "thumb": "", "authToken": member.plexTVToken,
        ] as DemoJSON)
    }

    /// The members of the Home, the way `/api/v2/home/users` lists them.
    func homeUsers() -> DemoResponse {
        let users = DemoHome.members.enumerated().map { index, member -> DemoJSON in
            [
                "id": index + 1, "uuid": member.uuid, "title": member.title, "username": member.isRestricted ? "" : member.title.lowercased(),
                "thumb": "", "admin": member.isAdmin, "guest": false, "restricted": member.isRestricted,
                "protected": member.isProtected, "home": true,
            ]
        }
        return .json(["id": 1, "name": "Demo Home", "guestUserID": NSNull(), "users": users] as DemoJSON)
    }

    /// Switches to a member: the member's plex.tv token, or 403 for a PIN that is missing or wrong, as plex.tv answers.
    func switchUser(uuid: String, pin: String?) -> DemoResponse {
        guard let member = DemoHome.member(uuid: uuid) else {
            return .json(["errors": [["code": 1001, "message": "User could not be found"]]], status: 404)
        }
        if let expected = member.pin, pin != expected {
            return .json(["errors": [["code": 1041, "message": "Invalid PIN"]]], status: 403)
        }
        return .json([
            "id": (DemoHome.members.firstIndex(of: member) ?? 0) + 1, "uuid": member.uuid, "title": member.title,
            "authToken": member.plexTVToken, "authenticationToken": member.plexTVToken,
        ] as DemoJSON, status: 201)
    }

    private func payload(_ pin: Pin, token: String?) -> DemoJSON {
        var fields: DemoJSON = [
            "id": pin.id, "code": pin.code, "product": pin.product, "trusted": false,
            "qr": "https://plex.tv/api/v2/pins/qr/\(pin.code)", "clientIdentifier": pin.clientIdentifier,
            "expiresIn": Self.pinLifetime, "createdAt": Self.iso(pin.createdAt),
            "expiresAt": Self.iso(pin.createdAt.addingTimeInterval(Double(Self.pinLifetime))),
        ]
        fields["authToken"] = token ?? NSNull()
        return fields
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

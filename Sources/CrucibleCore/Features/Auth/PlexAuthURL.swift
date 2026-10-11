import Foundation

/// The `app.plex.tv/auth` page that approves a strong PIN. The iPhone loads it in a web view; the
/// Apple TV renders it as a QR code. The URL form is the one the iPhone sign-in has always used.
package enum PlexAuthURL {
    package static func url(clientIdentifier: String, code: String) -> URL? {
        let client = encoded(clientIdentifier)
        let pin = encoded(code)
        return URL(string: "https://app.plex.tv/auth#?clientID=\(client)&code=\(pin)&context%5Bdevice%5D%5Bproduct%5D=Crucible")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

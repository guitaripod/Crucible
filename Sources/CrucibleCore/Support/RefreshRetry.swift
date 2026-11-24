import Foundation

/// How a screen tries a read of the server again after it failed, while what it shows would otherwise stay as it was before
/// the app was entered. An Apple TV woken from sleep, a phone brought back from a tunnel and a laptop whose lid was opened
/// all come to the front before their network does, and a Home that keeps the positions from before the sleep is exactly the
/// stale progress the viewer then watches from.
package enum RefreshRetry {
    /// The waits between attempts, measured from the failure of the one before: at most half a minute of them, which covers
    /// a Wi-Fi association and a route the server moved to while the app was away.
    package static let waits: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    /// Whether `error` is a failure of reaching the server rather than an answer to a question: only those are worth asking
    /// again, since a server that said no will keep saying no. The cases are the ones `APIClient` itself retries, which is
    /// half a second to four seconds of tries; an entry outlasts a network that takes longer to come back than that.
    package static func isTransport(_ error: any Error) -> Bool {
        switch error {
        case APIError.timedOut, APIError.serverUnavailable, APIError.rateLimited:
            return true
        case APIError.httpError(let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        case let urlError as URLError:
            return Self.transportCodes.contains(urlError.code)
        default:
            return false
        }
    }

    private static let transportCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
    ]
}

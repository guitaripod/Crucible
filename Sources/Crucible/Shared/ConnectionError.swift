import Foundation

/// Translates transport errors into actionable copy. The raw URLError descriptions ("A TLS error
/// caused the secure connection to fail") read as app bugs; these name what to actually do.
enum ConnectionError {
    static func message(for error: Error) -> String {
        if let apiError = error as? APIError, let description = apiError.errorDescription {
            return description
        }
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The server's secure certificate could not be verified. Crucible will look for another route on the next launch — or re-add the server from Settings."
        case .cannotFindHost, .dnsLookupFailed:
            return "Couldn't find the server. Check that its address is reachable from this network."
        case .cannotConnectToHost, .resourceUnavailable:
            return "Couldn't reach the server. It may be offline or unreachable from this network."
        case .notConnectedToInternet:
            return "No internet connection."
        case .timedOut:
            return "The request timed out. The server may be slow or unreachable."
        case .networkConnectionLost:
            return "The connection dropped. Try again."
        default:
            return urlError.localizedDescription
        }
    }
}
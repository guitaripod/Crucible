import Foundation

/// Asks plex.tv whether it still accepts an account token. Only an explicit 401 counts as
/// rejected: a network failure says nothing about the token.
package enum PlexTokenCheck {
    package static func isRejected(
        token: String,
        send: @Sendable (URLRequest) async throws -> Int = { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    ) async -> Bool {
        var request = URLRequest(url: PlexTVHost.account.appendingPathComponent("api/v2/user"))
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let status = try? await send(request) else { return false }
        return status == 401
    }
}

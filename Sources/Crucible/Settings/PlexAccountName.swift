import Foundation

/// Fetches the signed-in plex.tv account's display name so the You tab can greet the user.
enum PlexAccountName {
    static let defaultsKey = "plex_account_name"

    private struct Account: Decodable {
        let username: String?
        let title: String?
        let friendlyName: String?
    }

    /// Stores `title` (falling back to `username`) under `plex_account_name`. Every failure is ignored.
    static func refresh(token: String) async {
        guard let url = URL(string: "https://plex.tv/api/v2/user") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let account = try? JSONDecoder().decode(Account.self, from: data)
        else { return }

        let name = [account.title, account.username, account.friendlyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let name else { return }
        UserDefaults.standard.set(name, forKey: defaultsKey)
    }
}

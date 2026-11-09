import Foundation

/// The slice of the mirrored history every aggregate reads: one account on a multi-user server, none of the
/// libraries left out of Home and Statistics, and, for Everything, the plays Trakt knows that Plex does not.
struct StatsScope: Sendable {
    var accountID: Int?
    var excludedSections: [Int] = []
    var includesTrakt = false

    /// The relation the aggregates read: the Plex mirror, or it together with Trakt's own plays (`every_play`).
    var table: String { includesTrakt ? "every_play" : "play" }

    /// A SQL fragment to append to a `WHERE`; `column` is the account column, qualified when the
    /// query aliases the `play` table, and the library and source columns share its qualifier. Trakt's plays
    /// belong to the viewer, so the account filter lets them through.
    func clause(column: String = "accountID") -> String {
        let source = column.replacingOccurrences(of: "accountID", with: "source")
        var sql = ""
        if let accountID {
            sql = includesTrakt ? " AND (\(column) = \(accountID) OR \(source) = 'trakt')" : " AND \(column) = \(accountID)"
        }
        guard !excludedSections.isEmpty else { return sql }
        let section = column.replacingOccurrences(of: "accountID", with: "librarySectionID")
        let excluded = excludedSections.map(String.init).joined(separator: ",")
        sql += " AND (\(section) IS NULL OR \(section) NOT IN (\(excluded)))"
        return sql
    }
}

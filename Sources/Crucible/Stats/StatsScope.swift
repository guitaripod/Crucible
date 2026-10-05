import Foundation

/// The slice of the mirrored history every aggregate reads: one account on a multi-user server, and
/// none of the libraries left out of Home and Statistics.
struct StatsScope: Sendable {
    var accountID: Int?
    var excludedSections: [Int] = []

    /// A SQL fragment to append to a `WHERE`; `column` is the account column, qualified when the
    /// query aliases the `play` table, and the library column shares its qualifier.
    func clause(column: String = "accountID") -> String {
        var sql = accountID.map { " AND \(column) = \($0)" } ?? ""
        guard !excludedSections.isEmpty else { return sql }
        let section = column.replacingOccurrences(of: "accountID", with: "librarySectionID")
        let excluded = excludedSections.map(String.init).joined(separator: ",")
        sql += " AND (\(section) IS NULL OR \(section) NOT IN (\(excluded)))"
        return sql
    }
}

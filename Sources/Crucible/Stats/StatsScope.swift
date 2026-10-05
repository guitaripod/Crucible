import Foundation

/// The slice of the mirrored history every aggregate reads: one account on a multi-user server, and
/// none of the libraries the server hides from Home.
struct StatsScope: Sendable {
    var accountID: Int?
    var hiddenSections: [Int] = []

    /// A SQL fragment to append to a `WHERE`; `column` is the account column, qualified when the
    /// query aliases the `play` table, and the library column shares its qualifier.
    func clause(column: String = "accountID") -> String {
        var sql = accountID.map { " AND \(column) = \($0)" } ?? ""
        guard !hiddenSections.isEmpty else { return sql }
        let section = column.replacingOccurrences(of: "accountID", with: "librarySectionID")
        let hidden = hiddenSections.map(String.init).joined(separator: ",")
        sql += " AND (\(section) IS NULL OR \(section) NOT IN (\(hidden)))"
        return sql
    }
}

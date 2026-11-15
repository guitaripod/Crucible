import Foundation

/// Where a Sports Research screen gets its report and sends the owner's changes: the paired Crucible Server, or a fixture
/// in screenshots and UI tests.
package protocol SportsSource: Sendable {
    func sports() async throws(CompanionError) -> SportsReport
    /// Whether the server has Sports Research at all (a server from before it answers its routes with nothing useful), or
    /// nil when the server could not be asked.
    func hasSports() async -> Bool?
    func changeSports(on: Bool?, libraries: [String]?, agree: Bool?) async throws(CompanionError)
    func recheckSports() async throws(CompanionError)
    func runSports() async throws(CompanionError)
    func redoSports(ratingKey: String) async throws(CompanionError)
}

extension CompanionClient: SportsSource {
    package func hasSports() async -> Bool? {
        guard let hello = try? await hello() else { return nil }
        return hello.sports == true
    }
}

/// A report read from a JSON file in the shape `GET /sports` answers, whose changes go nowhere.
package struct SportsFixture: SportsSource {
    private let url: URL

    package init(url: URL) {
        self.url = url
    }

    package func sports() async throws(CompanionError) -> SportsReport {
        guard let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(SportsReport.self, from: data) else {
            throw .failed("No Sports Research fixture at \(url.path)")
        }
        return report
    }

    package func hasSports() async -> Bool? { true }
    package func changeSports(on: Bool?, libraries: [String]?, agree: Bool?) async throws(CompanionError) {}
    package func recheckSports() async throws(CompanionError) {}
    package func runSports() async throws(CompanionError) {}
    package func redoSports(ratingKey: String) async throws(CompanionError) {}
}

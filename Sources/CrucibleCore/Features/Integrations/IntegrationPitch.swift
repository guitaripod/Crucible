import Foundation

/// Why connect an integration, in the words its settings screen opens with on every platform: a headline, a short story of
/// what changes, and the benefits one by one, with the ones Crucible Pro adds marked.
package struct IntegrationPitch: Sendable {
    package struct Benefit: Sendable, Hashable {
        package let symbol: String
        package let title: String
        package let detail: String
        package let needsPro: Bool

        package init(symbol: String, title: String, detail: String, needsPro: Bool = false) {
            self.symbol = symbol
            self.title = title
            self.detail = detail
            self.needsPro = needsPro
        }
    }

    package let headline: String
    package let story: String
    package let benefits: [Benefit]

    /// The badge on a benefit that needs Crucible Pro.
    package static let proBadge = String(localized: "Pro", comment: "Badge on an integration benefit that needs Crucible Pro")
}

import CrucibleCore

extension IntegrationPitch {
    /// The headline and the story, for the context column of an integration's settings screen on Apple TV.
    var contextText: String {
        headline + "\n" + story
    }

    /// The benefits as rows under the screen's actions: read, not chosen, with the ones that need Crucible Pro marked.
    func benefitRows(idPrefix: String) -> [TVRowItem] {
        benefits.enumerated().map { index, benefit in
            TVRowItem(
                id: "\(idPrefix).benefit\(index)",
                title: benefit.title,
                subtitle: benefit.detail,
                value: benefit.needsPro ? Self.proBadge : nil,
                symbol: benefit.symbol,
                isStatic: true
            )
        }
    }
}

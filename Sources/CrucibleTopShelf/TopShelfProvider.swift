import CrucibleCore
import TVServices

/// The Top Shelf extension's content provider. It only reads the snapshot the app left in the App
/// Group container and maps it to TVServices types: no networking, no image work. With nothing to
/// show it returns nil so the system displays the static branded Top Shelf image.
open class TopShelfProvider: TVTopShelfContentProvider {
    open override func loadTopShelfContent(completionHandler: @escaping @Sendable ((any TVTopShelfContent)?) -> Void) {
        let store = TopShelfStore.shared
        let snapshot = store.load()
        let plan = TopShelfPlan(snapshot: snapshot)
        store.saveReceipt(
            TopShelfReceipt(
                itemCount: plan?.items.count ?? 0,
                imageCount: plan?.items.filter { $0.imageURL != nil }.count ?? 0,
                snapshotSchema: snapshot?.schema
            )
        )
        AppLogger.info(
            "Top Shelf extension: \(plan?.items.count ?? 0) items, schema \(snapshot.map { String($0.schema) } ?? "none"), snapshot \(store.existingSnapshotPath ?? "none")",
            .lifecycle
        )
        completionHandler(plan.map(Self.content(for:)))
    }

    private static func content(for plan: TopShelfPlan) -> TVTopShelfCarouselContent {
        TVTopShelfCarouselContent(style: .details, items: plan.items.map(carouselItem(for:)))
    }

    private static func carouselItem(for item: TopShelfPlan.Item) -> TVTopShelfCarouselItem {
        let card = TVTopShelfCarouselItem(identifier: item.identifier)
        card.title = item.title
        card.contextTitle = item.contextTitle
        card.summary = item.summary
        card.setImageURL(item.imageURL, for: .screenScale1x)
        card.setImageURL(item.image2xURL, for: .screenScale2x)
        card.playAction = item.playURL.map { TVTopShelfAction(url: $0) }
        card.displayAction = TVTopShelfAction(url: item.displayURL)
        return card
    }
}

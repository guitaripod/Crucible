import CrucibleCore
import TVServices

/// The Top Shelf extension's content provider. It only reads the snapshot the app left in the App
/// Group container and maps it to TVServices types: no networking, no image work. With nothing to
/// show it returns nil so the system displays the static branded Top Shelf image.
open class TopShelfProvider: TVTopShelfContentProvider {
    open override func loadTopShelfContent(completionHandler: @escaping @Sendable ((any TVTopShelfContent)?) -> Void) {
        let plan = TopShelfPlan(snapshot: TopShelfStore.shared.load())
        completionHandler(plan.map(Self.content(for:)))
    }

    private static func content(for plan: TopShelfPlan) -> TVTopShelfSectionedContent {
        TVTopShelfSectionedContent(sections: plan.sections.map(collection(for:)))
    }

    private static func collection(for section: TopShelfPlan.Section) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let collection = TVTopShelfItemCollection(items: section.items.map(sectionedItem(for:)))
        collection.title = section.title
        return collection
    }

    private static func sectionedItem(for item: TopShelfPlan.Item) -> TVTopShelfSectionedItem {
        let tile = TVTopShelfSectionedItem(identifier: item.identifier)
        tile.title = item.title
        tile.imageShape = .hdtv
        tile.setImageURL(item.imageURL, for: [.screenScale1x, .screenScale2x])
        if let progress = item.progress {
            tile.playbackProgress = progress
        }
        tile.playAction = item.playURL.map { TVTopShelfAction(url: $0) }
        tile.displayAction = TVTopShelfAction(url: item.displayURL)
        return tile
    }
}

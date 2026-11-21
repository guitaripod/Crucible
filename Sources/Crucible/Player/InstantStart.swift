import CrucibleCore
import CrucibleMedia
import UIKit

/// What the iPhone, iPad and Mac screens tell Instant Start (`PlaybackWarmUp`) about the viewer: a title's page is open, a
/// finger went down on a card that plays, a pointer came to rest on one.
@MainActor
enum InstantStart {
    /// The viewer may be about to play `item` the way a tap on it plays it, from where the server has it. A downloaded
    /// title plays from disk and needs nothing.
    static func warm(api: APIClient, item: PlexMetadata, intent: PlayIntent) {
        guard HomeMediaRules.isPlayable(item), DownloadManager.shared.offlineAsset(for: item.id) == nil else { return }
        PlaybackWarmUp.shared.warm(api: api, request: PlaybackRequest(item: item), intent: intent)
    }

    /// The viewer left the screen that spoke for `ratingKey`.
    static func cool(_ ratingKey: String?) {
        guard let ratingKey else { return }
        PlaybackWarmUp.shared.cool(ratingKey: ratingKey)
    }
}

/// Follows a pointer over a collection view, on an iPad with a trackpad or a Mac, and tells Instant Start when it comes to
/// rest on a card that plays when clicked. `item` answers what the card at an index path plays, or nil when a click on it
/// does something else.
@MainActor
final class PointerRest: NSObject {
    private let api: APIClient
    private let item: @MainActor (IndexPath) -> PlexMetadata?
    private let watch = RestWatch { InstantStart.cool($0) }

    init(on collectionView: UICollectionView, api: APIClient, item: @escaping @MainActor (IndexPath) -> PlexMetadata?) {
        self.api = api
        self.item = item
        super.init()
        collectionView.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed,
              let collectionView = recognizer.view as? UICollectionView,
              let indexPath = collectionView.indexPathForItem(at: recognizer.location(in: collectionView)),
              let item = item(indexPath) else {
            watch.moved(onto: nil)
            return
        }
        watch.moved(onto: item.id) { [api] intent in
            InstantStart.warm(api: api, item: item, intent: intent)
        }
    }
}

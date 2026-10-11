import CrucibleDesign
import UIKit

/// The host every collection-based tvOS screen is built on: a `TVCollectionView` and a `TVStateView`
/// pinned to the screen's edges, with the focus rules written once.
///
/// - `show(state:)` and `showContent()` swap the two views. While a state without a button is
///   showing, focus sits on the state view's anchor, so Menu pops the screen instead of leaving the
///   app; when the content returns, focus moves back to the collection.
/// - Focus is remembered by item identifier (`adopt(_:)` wires the diffable data source), so a
///   refresh that shifts positions still restores the right card. `initialFocusIndexPath()` is the
///   only focus hook a screen normally overrides.
/// - Play/Pause on a focused item goes to `playFocused(at:)`; a screen that does not handle it
///   returns false and the press continues up the responder chain.
/// - `makeTaskSlot()` returns a `TVTaskSlot` that is cancelled when the screen disappears.
///
/// A screen with its own layout (Detail, Settings) overrides `installViews()`.
class TVScreenViewController: UIViewController, UICollectionViewDelegate {
    final let collectionView: TVCollectionView
    final let stateView = TVStateView()
    final let focusMemory = TVFocusMemory()

    private let hostAnchor = TVFocusAnchorView()
    private var slots: [TVTaskSlot] = []
    private var identifierForIndexPath: ((IndexPath) -> AnyHashable?)?
    private var indexPathForIdentifier: ((AnyHashable) -> IndexPath?)?
    private var hasItems: (() -> Bool)?

    init(layout: UICollectionViewLayout) {
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    final var isShowingState: Bool { !stateView.isHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.playPauseHandler = { [weak self] indexPath in self?.playFocused(at: indexPath) ?? false }
        installViews()
        stateView.isHidden = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        slots.forEach { $0.cancelUnlessKeptAlive() }
    }

    /// Adds the collection view, the state view and the focus fallback, pinned to the view's edges.
    /// Override to place them differently; call `super` for the default layout.
    func installViews() {
        [collectionView, stateView, hostAnchor].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostAnchor.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hostAnchor.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hostAnchor.widthAnchor.constraint(equalToConstant: 2),
            hostAnchor.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    /// Wires the diffable data source so focus can be remembered and restored by item identifier.
    final func adopt<Section: Hashable & Sendable, Item: Hashable & Sendable>(_ dataSource: UICollectionViewDiffableDataSource<Section, Item>) {
        identifierForIndexPath = { [weak dataSource] in dataSource?.itemIdentifier(for: $0).map { AnyHashable($0) } }
        indexPathForIdentifier = { [weak dataSource] identifier in
            (identifier.base as? Item).flatMap { dataSource?.indexPath(for: $0) }
        }
        hasItems = { [weak dataSource] in (dataSource?.snapshot().numberOfItems ?? 0) > 0 }
    }

    final func makeTaskSlot() -> TVTaskSlot {
        let slot = TVTaskSlot()
        slots.append(slot)
        return slot
    }

    /// Replaces the content with a state. Focus moves to the state's button, or to the anchor when it
    /// has none, whenever it was inside the screen's content or state.
    final func show(state: TVStateView.State) {
        let hadFocus = ownsFocus
        collectionView.isHidden = true
        stateView.isHidden = false
        stateView.show(state)
        if hadFocus { requestFocusUpdate() }
    }

    /// Shows the collection again. If focus was on the state view's button or anchor, it moves to the
    /// collection's preferred item.
    final func showContent() {
        let hadFocus = ownsFocus
        stateView.isHidden = true
        collectionView.isHidden = false
        if hadFocus { requestFocusUpdate() }
    }

    /// Which item gets focus when nothing was remembered. Nil lets the focus engine choose.
    func initialFocusIndexPath() -> IndexPath? { nil }

    /// Handles Play/Pause on the focused item; return false to decline.
    func playFocused(at indexPath: IndexPath) -> Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if isShowingState { return [stateView] }
        if hasItems?() ?? true { return [collectionView] }
        return [hostAnchor]
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        focusMemory.preferredIndexPath(resolving: { [indexPathForIdentifier] in indexPathForIdentifier?($0) }) ?? initialFocusIndexPath()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        focusMemory.record(context, identifier: context.nextFocusedIndexPath.flatMap { identifierForIndexPath?($0) })
    }

    private var ownsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: view)
    }

    private func requestFocusUpdate() {
        view.layoutIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

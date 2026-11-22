import UIKit

/// The TV guide's grid on the iPhone, the iPad and the Apple TV: one section per channel, one item per airing placed by its
/// time on a timeline that starts at `origin`, the channel column pinned to the leading edge and the time ruler to the top,
/// and a line at the present moment. An airing that began before the visible edge starts at that edge, so its title stays
/// readable and the focus engine never scrolls a cell under the channel column. Compositional layout cannot pin a column
/// while every row scrolls through time together, which is why the guide has a layout of its own.
package final class LiveGuideLayout: UICollectionViewLayout {
    package static let channelKind = "live.channel"
    package static let timeKind = "live.time"
    package static let cornerKind = "live.corner"
    package static let nowKind = "live.now"

    /// Where the timeline begins.
    package var origin = Date() { didSet { invalidateLayout() } }
    /// How many hours the timeline spans.
    package var hours: Double = 12 { didSet { invalidateLayout() } }
    /// The airings of each section, in item order.
    package var rows: [[DateInterval]] = [] { didSet { invalidateLayout() } }
    /// The present moment, where the line is drawn.
    package var now = Date() { didSet { invalidateLayout() } }

    private var channelWidth: CGFloat { Theme.LiveGuide.channelWidth }
    private var rowHeight: CGFloat { Theme.LiveGuide.rowHeight }
    private var pitch: CGFloat { Theme.LiveGuide.rowHeight + Theme.LiveGuide.rowSpacing }
    private var headerHeight: CGFloat { Theme.LiveGuide.headerHeight }
    private var pointsPerHour: CGFloat { Theme.LiveGuide.pointsPerHour }
    private var spacing: CGFloat { Theme.LiveGuide.cellSpacing }
    private static let slot: TimeInterval = 1800

    package var slotCount: Int { max(Int((hours * 3600 / Self.slot).rounded(.up)), 1) }

    package func slotStart(_ index: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(index) * Self.slot)
    }

    package override var collectionViewContentSize: CGSize {
        CGSize(width: channelWidth + CGFloat(hours) * pointsPerHour, height: headerHeight + CGFloat(rows.count) * pitch)
    }

    package override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    private var visible: CGRect { collectionView?.bounds ?? .zero }

    /// The top-leading corner of what shows inside the bars: the ruler and the channel column are pinned here.
    private var pin: CGPoint {
        guard let collectionView else { return .zero }
        let inset = collectionView.adjustedContentInset
        return CGPoint(x: collectionView.bounds.minX + inset.left, y: collectionView.bounds.minY + inset.top)
    }

    private func x(of date: Date) -> CGFloat {
        channelWidth + CGFloat(date.timeIntervalSince(origin) / 3600) * pointsPerHour
    }

    /// The x at which a time from the timeline is at the present moment, in content coordinates.
    package var nowX: CGFloat { x(of: now) }

    /// The content offset that puts `date` at the leading edge of the grid.
    package func offset(showing date: Date) -> CGFloat {
        max(x(of: date) - channelWidth, 0)
    }

    private func itemFrame(_ indexPath: IndexPath) -> CGRect? {
        guard rows.indices.contains(indexPath.section), rows[indexPath.section].indices.contains(indexPath.item) else { return nil }
        let span = rows[indexPath.section][indexPath.item]
        let left = x(of: span.start)
        let right = x(of: span.end) - spacing
        let leadingEdge = pin.x + channelWidth + spacing
        let clippedLeft = max(left, leadingEdge, channelWidth + spacing)
        guard right - clippedLeft > 1 else { return CGRect(x: left, y: y(ofRow: indexPath.section), width: max(right - left, 1), height: rowHeight) }
        return CGRect(x: clippedLeft, y: y(ofRow: indexPath.section), width: right - clippedLeft, height: rowHeight)
    }

    private func y(ofRow row: Int) -> CGFloat {
        headerHeight + CGFloat(row) * pitch
    }

    private func rowRange(in rect: CGRect) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = max(Int(((rect.minY - headerHeight) / pitch).rounded(.down)), 0)
        let last = min(Int(((rect.maxY - headerHeight) / pitch).rounded(.up)), rows.count - 1)
        return first <= last ? first..<(last + 1) : 0..<0
    }

    package override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        let range = rowRange(in: rect.union(visible))
        for row in range {
            for (index, span) in rows[row].enumerated() {
                guard x(of: span.end) >= rect.minX, x(of: span.start) <= rect.maxX else { continue }
                if let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: row)) { result.append(attributes) }
            }
            if let channel = layoutAttributesForSupplementaryView(ofKind: Self.channelKind, at: IndexPath(item: 0, section: row)) { result.append(channel) }
        }
        let firstSlot = max(Int(((visible.minX) / pointsPerHour * 3600 / Self.slot).rounded(.down)) - 1, 0)
        let lastSlot = min(Int(((visible.maxX) / pointsPerHour * 3600 / Self.slot).rounded(.up)) + 1, slotCount - 1)
        if firstSlot <= lastSlot {
            for slot in firstSlot...lastSlot {
                if let time = layoutAttributesForSupplementaryView(ofKind: Self.timeKind, at: IndexPath(item: slot, section: 0)) { result.append(time) }
            }
        }
        if !rows.isEmpty {
            if let corner = layoutAttributesForSupplementaryView(ofKind: Self.cornerKind, at: IndexPath(item: 0, section: 0)) { result.append(corner) }
            if let line = layoutAttributesForSupplementaryView(ofKind: Self.nowKind, at: IndexPath(item: 0, section: 0)), line.frame.intersects(rect) { result.append(line) }
        }
        return result
    }

    package override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frame = itemFrame(indexPath) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        attributes.zIndex = 1
        return attributes
    }

    package override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        switch elementKind {
        case Self.channelKind:
            guard rows.indices.contains(indexPath.section) else { return nil }
            attributes.frame = CGRect(x: pin.x, y: y(ofRow: indexPath.section), width: channelWidth - spacing, height: rowHeight)
            attributes.zIndex = 20
        case Self.timeKind:
            let left = x(of: slotStart(indexPath.item))
            attributes.frame = CGRect(x: left, y: pin.y, width: pointsPerHour / 2, height: headerHeight)
            attributes.zIndex = 30
        case Self.cornerKind:
            attributes.frame = CGRect(x: pin.x, y: pin.y, width: channelWidth, height: headerHeight)
            attributes.zIndex = 40
        case Self.nowKind:
            let width = Theme.LiveGuide.nowLineWidth
            let left = nowX - width / 2
            guard left >= pin.x + channelWidth - width else {
                attributes.frame = CGRect(x: left, y: pin.y, width: width, height: 0)
                attributes.isHidden = true
                return attributes
            }
            attributes.frame = CGRect(x: left, y: pin.y + headerHeight * 0.55, width: width, height: max(visible.maxY - pin.y - headerHeight * 0.55, 0))
            attributes.zIndex = 10
        default:
            return nil
        }
        return attributes
    }

    package override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let collectionView else { return proposedContentOffset }
        let size = collectionViewContentSize
        return CGPoint(x: min(max(proposedContentOffset.x, 0), max(size.width - collectionView.bounds.width, 0)),
                       y: min(max(proposedContentOffset.y, -collectionView.adjustedContentInset.top), max(size.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom, 0)))
    }
}

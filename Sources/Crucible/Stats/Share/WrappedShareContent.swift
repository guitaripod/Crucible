@preconcurrency import UIKit

/// Everything the share poster draws, resolved up front so rendering is pure drawing and the same
/// content can be laid out for any format.
struct WrappedShareContent {
    struct Title {
        let rank: Int
        let name: String
        let caption: String
        let poster: UIImage?
        let placeholderSymbol: String
    }

    struct Figure {
        let value: String
        let label: String
    }

    let period: String
    let shareTitle: String
    let eyebrow: String
    let heroValue: String
    let heroUnit: String
    let heroDetail: String
    let figures: [Figure]
    let titles: [Title]
    let genres: [String]
    let heatmap: HeatmapModel?
    let summary: String

    var leadPoster: UIImage? { titles.first?.poster }
}

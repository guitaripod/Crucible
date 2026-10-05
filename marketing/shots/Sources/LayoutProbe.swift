import UIKit
@testable import Crucible

@MainActor
enum LayoutProbe {
    static func run() {
        var out = ""
        func probe(_ name: String, _ view: UIView, width: CGFloat) {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 10)
            let size = view.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            out += "\(name): \(size) ambiguous=\(view.hasAmbiguousLayout)\n"
            let expanded = view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingExpandedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            out += "   expandedTarget: \(expanded)\n"
            let low = view.systemLayoutSizeFitting(
                CGSize(width: width, height: 10_000),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .defaultLow
            )
            out += "   lowPriority10000: \(low)\n"
        }
        var header = LibraryHeaderConfiguration()
        header.chips = [.init(id: "all", title: "All", isSelected: true), .init(id: "u", title: "Unwatched")]
        probe("libraryHeader.noBanner", LibraryHeaderContentView(configuration: header), width: 440)
        header.banner = ContinueBannerModel(itemId: "1", detail: "Deep Field · 1 h 12 m left", artPath: nil, spokenLabel: "x")
        probe("libraryHeader.banner", LibraryHeaderContentView(configuration: header), width: 440)
        probe("chips", { let v = FilterChipsView(); v.setChips(header.chips); return v }(), width: 440)
        probe("banner", { let v = ContinueBannerView(); v.apply(header.banner!); return v }(), width: 408)
        var section = SectionHeaderConfiguration(); section.title = "Up Next"; section.actionTitle = "See All"
        probe("sectionHeader", SectionHeaderContentView(configuration: section), width: 408)
        var poster = PosterContentConfiguration(); poster.title = "Halcyon"; poster.subtitle = "2021"
        probe("poster", PosterContentView(configuration: poster), width: 120)
        var landscape = LandscapeContentConfiguration(); landscape.title = "Low Tide"; landscape.subtitle = "S2 E4"
        probe("landscape", LandscapeContentView(configuration: landscape), width: 232)
        try? FileManager.default.createDirectory(atPath: ShotHarness.signalDirectory, withIntermediateDirectories: true)
        try? out.write(toFile: "\(ShotHarness.signalDirectory)/probe.txt", atomically: true, encoding: .utf8)
    }
}

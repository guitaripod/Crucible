import UIKit
@testable import Crucible
@testable import CrucibleCore

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
        probe("traktUnlock", TraktUnlockCardContentView(configuration: TraktUnlockCardConfiguration(count: 42)), width: 340)
        let invite = TraktInvite(kind: .connect, title: "Connect Trakt", message: "Connect Trakt to see its score beside IMDb and Rotten Tomatoes, the reviews, and what people say about this title.", action: "Connect Trakt")
        probe("traktInvite", TraktInviteCardContentView(configuration: TraktInviteCardConfiguration(invite: invite)), width: 340)
        var member = TraktMemberRowConfiguration(user: TraktUser(username: "marcus", name: "Marcus"), reactions: [])
        probe("traktMemberRow", TraktMemberRowContentView(configuration: member), width: 340)
        member.user = TraktUser(username: "marcus", name: "Marcus", isVIP: true, isDirector: true)
        probe("traktMemberRow.badges", TraktMemberRowContentView(configuration: member), width: 340)
        probe("seerrHeader", SeerrTitleHeaderView(configuration: SeerrTitleHeaderConfiguration(title: "Deep Field", year: 2021, availability: nil, overview: "A crew reads the sound of the ice.", poster: nil)), width: 340)
        probe("seerrGuideCommand", GuideCommandView(configuration: GuideCommandConfiguration(command: "docker pull lscr.io/linuxserver/seerr:latest", copied: false, onCopy: {})), width: 440)
        probe("watchPick", WatchPickContentView(configuration: WatchPickConfiguration(title: "Deep Field", facts: "2019 · 1 h 48 m · Science", why: "It fits the quiet evening you asked for.")), width: 340)
        probe("sportsPill", SportsPillView(configuration: SportsPillConfiguration(symbol: "bolt", tint: .systemBlue, title: "Researching", detail: "Reading 1 file", progress: nil, working: true, action: nil)), width: 440)
        probe("sportsHero", SportsHeroView(configuration: SportsHeroConfiguration(label: "New", file: "deep.field.2021.mkv", title: "Deep Field", meta: "2021 · 1 h 48 m", posterPath: nil, posterWords: nil, kind: .sports, isExample: false, playsChange: false)), width: 440)
        let setupStep = SportsSetupStep(group: .plex, number: 1, checks: [])
        let settings = SportsSettings(on: false, agreed: false)
        probe("sportsStep", SportsStepView(configuration: SportsStepConfiguration(step: setupStep, total: 4, expanded: true, owner: true, settings: settings, libraries: [], busy: false, actions: SportsStepActions())), width: 440)
        try? FileManager.default.createDirectory(atPath: ShotHarness.signalDirectory, withIntermediateDirectories: true)
        try? out.write(toFile: "\(ShotHarness.signalDirectory)/probe.txt", atomically: true, encoding: .utf8)
    }
}

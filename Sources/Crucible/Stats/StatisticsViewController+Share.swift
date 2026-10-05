@preconcurrency import UIKit

extension StatisticsViewController {
    /// Builds the poster content, then opens the preview sheet; the button shows progress while the
    /// top posters download.
    func shareWrapped(from button: UIButton?) {
        guard !current.isEmpty else { return }
        button?.configuration?.showsActivityIndicator = true
        button?.isUserInteractionEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let content = await shareContent()
            button?.configuration?.showsActivityIndicator = false
            button?.isUserInteractionEnabled = true
            let preview = UINavigationController(rootViewController: WrappedSharePreviewViewController(content: content))
            preview.sheetPresentationController?.prefersGrabberVisible = true
            present(preview, animated: true)
        }
    }

    func shareContent() async -> WrappedShareContent {
        let snapshot = current
        let overview = snapshot.overview
        let hero = heroContent()
        let titles = await rankedTitles(in: snapshot)
        let binge = longestBinge()
        let year = statsTime.calendar.component(.year, from: Date())
        let figures = [
            WrappedShareContent.Figure(value: StatsStyle.abbreviatedCount(overview.totalPlays), label: "Plays"),
            WrappedShareContent.Figure(value: "\(overview.daysActive)", label: "Days Active"),
            WrappedShareContent.Figure(value: "\(overview.longestStreak)", label: "Day Streak"),
            binge.map { WrappedShareContent.Figure(value: $0.value.replacingOccurrences(of: " ", with: ""), label: "Longest Binge") }
                ?? WrappedShareContent.Figure(value: StatsStyle.abbreviatedCount(overview.showsWatched + overview.moviesWatched), label: "Titles"),
        ]
        let value = hero.value.formatted()
        let detail = hero.detail.components(separatedBy: " · ").first ?? hero.detail
        let period = periodLabel(year: year)
        let summary = "\(shareHeadline(year: year)): \(value) \(hero.unit) \(detail), \(overview.totalPlays) plays, \(overview.daysActive) days active."
            + (titles.isEmpty ? "" : " Most watched: \(titles.map(\.name).joined(separator: ", ")).")
        return WrappedShareContent(
            period: period,
            shareTitle: shareHeadline(year: year),
            eyebrow: hero.eyebrow,
            heroValue: value,
            heroUnit: hero.unit,
            heroDetail: detail,
            figures: figures,
            titles: titles,
            genres: snapshot.genres.prefix(4).map(\.genre),
            heatmap: heatmapModel.cells.isEmpty ? nil : heatmapModel,
            summary: summary
        )
    }

    private func periodLabel(year: Int) -> String {
        switch range {
        case .week: return "LAST 7 DAYS"
        case .month: return "LAST 30 DAYS"
        case .year: return "\(year)"
        case .allTime: return "ALL TIME"
        }
    }

    private func shareHeadline(year: Int) -> String {
        switch range {
        case .week: return "My Week in Crucible"
        case .month: return "My Month in Crucible"
        case .year: return "My \(year) in Crucible"
        case .allTime: return "My Crucible, All Time"
        }
    }

    /// The three most-played titles across shows and movies, each with its poster. Ties go to shows.
    private func rankedTitles(in snapshot: StatsSnapshot) async -> [WrappedShareContent.Title] {
        struct Entry {
            let name: String
            let thumb: String?
            let count: Int
            let isShow: Bool
        }
        let shows = snapshot.topShows.map { Entry(name: $0.title, thumb: $0.thumb, count: $0.count, isShow: true) }
        let movies = snapshot.topMovies.map { Entry(name: $0.title, thumb: $0.thumb, count: $0.count, isShow: false) }
        let top = (shows + movies).enumerated()
            .sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
            .prefix(3)
            .map(\.element)
        var posters = [Int: UIImage]()
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, entry) in top.enumerated() {
                guard let path = entry.thumb else { continue }
                group.addTask { (index, await ImageLoader.shared.loadImage(path: path, width: 480)) }
            }
            for await (index, image) in group {
                if let image { posters[index] = image }
            }
        }
        return top.enumerated().map { index, entry in
            WrappedShareContent.Title(
                rank: index + 1,
                name: entry.name,
                caption: entry.isShow
                    ? "\(entry.count) \(entry.count == 1 ? "episode" : "episodes")"
                    : (entry.count == 1 ? "Movie" : "Movie · \(entry.count) plays"),
                poster: posters[index],
                placeholderSymbol: entry.isShow ? "tv" : "film"
            )
        }
    }
}

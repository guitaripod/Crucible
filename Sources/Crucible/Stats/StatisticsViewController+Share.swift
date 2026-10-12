import CrucibleCore
import CrucibleDesign
import CrucibleStats
@preconcurrency import UIKit

extension StatisticsViewController {
    /// Opens the poster preview once the page has loaded, when the demo tour asked for it; a screen the user has left is left alone.
    func openPosterIfAsked() {
        guard opensPosterWhenLoaded, !page.isEmpty, view.window != nil, presentedViewController == nil else { return }
        opensPosterWhenLoaded = false
        shareWrapped(from: nil)
    }

    /// Opens the poster preview. The poster is Pro: a free install gets the paywall first and the preview only if Pro comes on.
    func shareWrapped(from button: UIButton?) {
        guard !page.isEmpty else { return }
        guard ProAccess.shared.hasFullAccess else {
            ProAccess.shared.requestUnlock(.yearInReviewPoster) { [weak self, weak button] unlocked in
                guard unlocked else { return }
                self?.previewWrapped(from: button)
            }
            return
        }
        previewWrapped(from: button)
    }

    /// Builds the poster content, then opens the preview sheet; the button shows progress while the
    /// top posters download.
    private func previewWrapped(from button: UIButton?) {
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
        let facts = StatsShareFacts(page: page, time: statsTime)
        let posters = await loadPosters(for: facts.titles)
        return WrappedShareContent(
            period: facts.period,
            shareTitle: facts.shareTitle,
            eyebrow: facts.eyebrow,
            heroValue: facts.heroValue,
            heroUnit: facts.heroUnit,
            heroDetail: facts.heroDetail,
            figures: facts.figures.map { WrappedShareContent.Figure(value: $0.value, label: $0.label) },
            titles: facts.titles.enumerated().map { index, title in
                WrappedShareContent.Title(
                    rank: title.rank,
                    name: title.name,
                    caption: title.caption,
                    poster: posters[index],
                    placeholderSymbol: title.placeholderSymbol
                )
            },
            genres: facts.genres,
            heatmap: facts.heatmap,
            summary: facts.summary
        )
    }

    private func loadPosters(for titles: [StatsShareFacts.Title]) async -> [Int: UIImage] {
        var posters = [Int: UIImage]()
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, title) in titles.enumerated() {
                guard let path = title.thumb else { continue }
                group.addTask { (index, await ImageLoader.shared.loadImage(path: path, width: 480)) }
            }
            for await (index, image) in group {
                if let image { posters[index] = image }
            }
        }
        return posters
    }
}

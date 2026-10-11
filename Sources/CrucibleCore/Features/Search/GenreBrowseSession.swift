import Foundation

package enum GenreBrowseState: Equatable, Sendable {
    case loading
    case loaded([PlexMetadata])
    case empty
    case failed(message: String)
}

@MainActor
package final class GenreBrowseSession {
    package let genre: SearchGenre
    package var onChange: ((GenreBrowseState) -> Void)?
    package private(set) var state: GenreBrowseState = .loading

    private let loader: SearchLoader
    private var loadTask: Task<Void, Never>?

    package init(genre: SearchGenre, loader: SearchLoader) {
        self.genre = genre
        self.loader = loader
    }

    deinit {
        loadTask?.cancel()
    }

    /// Loads every title of the genre. Calling it again cancels the load in flight, which is how Try Again works.
    package func load() {
        loadTask?.cancel()
        emit(.loading)
        loadTask = Task { [weak self, loader, genre] in
            do {
                let items = try await loader.items(genre: genre)
                guard !Task.isCancelled, let self else { return }
                emit(items.isEmpty ? .empty : .loaded(items))
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled, let self else { return }
                AppLogger.error("Genre browse failed genre=\(genre.title): \(error.localizedDescription)", .networking)
                emit(.failed(message: error.localizedDescription))
            }
        }
    }

    package func cancel() {
        loadTask?.cancel()
    }

    private func emit(_ newState: GenreBrowseState) {
        state = newState
        onChange?(newState)
    }
}

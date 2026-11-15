import CrucibleCore
import Foundation
import Kiln

/// The playing file's preview stills for the scrubber (`ScrubStills`): asked for one at a time as the pointer moves,
/// decoded into textures held only while the player is open, and the nearest held one standing in while the right one
/// loads. Nothing is written to the artwork cache: stills are throwaway.
@MainActor
final class ScrubStillLoader {
    /// A still arrived, so the scrubber should draw again.
    var onChange: (() -> Void)?

    let partID: Int
    private let api: APIClient
    private let fetch: ImageStore.Fetch
    private weak var window: Window?
    private var queue = ScrubStillQueue()
    private var stills: [Int: Texture] = [:]
    private var arrival: [Int] = []
    private var task: Task<Void, Never>?

    /// How many stills stay in memory (about 230 KB each at 320 by 180).
    private static let capacity = 120

    init(partID: Int, api: APIClient, window: Window?) {
        self.partID = partID
        self.api = api
        fetch = PlexArtworkPipeline.fetcher(token: api.token)
        self.window = window
    }

    deinit {
        task?.cancel()
    }

    /// The still for `seconds` into the title, or the nearest one held while it loads; nil when there is none to show.
    func still(at seconds: Double) -> Texture? {
        let second = ScrubStills.second(seconds)
        let held = stills[second]
        if let next = queue.want(second, held: held != nil) { load(next) }
        if let held { return held }
        return ScrubStillQueue.standIn(for: second, among: stills.keys).flatMap { stills[$0] }
    }

    private func load(_ second: Int) {
        let api = api
        let path = String(ScrubStills.path(partID: partID, second: second).dropFirst())
        let fetch = fetch
        task = Task { [weak self] in
            let data = try? await fetch(api.baseURL.appendingPathComponent(path))
            guard !Task.isCancelled, let self else { return }
            let texture = data.flatMap { try? self.window?.images?.texture(from: $0) }
            if let texture { self.keep(texture, at: second) }
            if let next = self.queue.landed(texture != nil) { self.load(next) }
            if texture != nil { self.onChange?() }
        }
    }

    private func keep(_ texture: Texture, at second: Int) {
        if stills.updateValue(texture, forKey: second) == nil { arrival.append(second) }
        while arrival.count > Self.capacity {
            stills[arrival.removeFirst()] = nil
        }
    }
}

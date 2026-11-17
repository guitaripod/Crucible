import CrucibleWeb
import Foundation
import Kiln

/// A web video's preview stills for the scrubber, cut from the site's storyboard: sheets of small stills in a grid. A
/// sheet is fetched and decoded the first time a still on it is asked for, and each still is uploaded from its place in
/// the sheet; the nearest still already held stands in meanwhile. Nothing is kept on disk.
@MainActor
final class WebStoryboardLoader {
    /// A still arrived, so the scrubber should draw again.
    var onChange: (() -> Void)?

    private let storyboard: WebStoryboard
    private weak var window: Window?
    private var sheets: [Int: DecodedImage] = [:]
    private var sheetOrder: [Int] = []
    private var loading: Set<Int> = []
    private var failed: Set<Int> = []
    private var stills: [Key: Texture] = [:]
    private var stillOrder: [Key] = []

    private struct Key: Hashable {
        let sheet: Int
        let x: Int
        let y: Int
    }

    /// How many decoded sheets (about 2 MB each at nine stills of 320 by 180) and uploaded stills stay in memory.
    private static let sheetCapacity = 6
    private static let stillCapacity = 120

    /// The sharpest storyboard of `video` whose sheets are few enough to fetch one at a time while scrubbing.
    init?(video: WebVideo, window: Window?) {
        guard let storyboard = video.storyboards.last(where: { $0.sheets.count <= 400 }) ?? video.storyboards.first else { return nil }
        self.storyboard = storyboard
        self.window = window
    }

    /// The still for `seconds` into the video, or the nearest one held while it loads; nil when there is none to show.
    func still(at seconds: Double) -> Texture? {
        guard let wanted = storyboard.still(at: seconds) else { return nil }
        let key = Key(sheet: wanted.sheet, x: wanted.x, y: wanted.y)
        if let held = stills[key] { return held }
        if let sheet = sheets[wanted.sheet] {
            if let texture = upload(wanted, from: sheet) {
                keep(texture, at: key)
                return texture
            }
            return nil
        }
        load(wanted.sheet)
        return stills.keys.filter { abs($0.sheet - wanted.sheet) <= 1 }.min { distance($0, key) < distance($1, key) }.flatMap { stills[$0] }
    }

    private func distance(_ a: Key, _ b: Key) -> Int {
        abs(a.sheet - b.sheet) * 1_000_000 + abs(a.y - b.y) * 100 + abs(a.x - b.x)
    }

    private func load(_ index: Int) {
        guard !loading.contains(index), !failed.contains(index), loading.count < 2, storyboard.sheets.indices.contains(index),
              let url = URL(string: storyboard.sheets[index].url) else { return }
        loading.insert(index)
        Task { [weak self] in
            let decoded: DecodedImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? await WebArtwork.data(from: url, timeout: 10) else { return nil }
                return try? ImageDecoder.decode(data)
            }.value
            guard let self else { return }
            self.loading.remove(index)
            guard let decoded else {
                self.failed.insert(index)
                return
            }
            self.sheets[index] = decoded
            self.sheetOrder.append(index)
            while self.sheetOrder.count > Self.sheetCapacity { self.sheets[self.sheetOrder.removeFirst()] = nil }
            self.onChange?()
        }
    }

    /// Uploads one still straight from its rows of the sheet, when the sheet is as large as the storyboard says.
    private func upload(_ still: WebStoryboard.Still, from sheet: DecodedImage) -> Texture? {
        guard let gpu = window?.gpu, let uploader = gpu.uploader, still.x + still.width <= sheet.width, still.y + still.height <= sheet.height
        else { return nil }
        let detached = sheet.pixels.withUnsafeBytes { bytes -> DetachedTexture? in
            guard let base = bytes.baseAddress else { return nil }
            return uploader.rgba8(width: still.width, height: still.height, pixels: base + (still.y * sheet.width + still.x) * 4, rowBytes: sheet.width * 4)
        }
        return detached.map(gpu.adopt)
    }

    private func keep(_ texture: Texture, at key: Key) {
        if stills.updateValue(texture, forKey: key) == nil { stillOrder.append(key) }
        while stillOrder.count > Self.stillCapacity { stills[stillOrder.removeFirst()] = nil }
    }
}

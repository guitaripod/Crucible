import CKilnImage
import Foundation

/// Decoded straight-alpha RGBA8 rows, top first.
public struct DecodedImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
}

/// An image off the decoding worker: already a texture when the device takes uploads from any thread, else pixels.
private enum LoadedImage: Sendable {
    case uploaded(DetachedTexture)
    case decoded(DecodedImage)
}

public enum ImageError: Error, CustomStringConvertible {
    case decode(String)
    case upload

    public var description: String {
        switch self {
        case .decode(let reason): "image decode failed: \(reason)"
        case .upload: "image upload failed"
        }
    }
}

/// JPEG (with DCT scaling), PNG and WebP decoding off the main actor.
public enum ImageDecoder {
    /// Decodes `data`, no smaller than `minimumWidth` by `minimumHeight` pixels when the format can decode smaller.
    public static func decode(_ data: Data, minimumWidth: Int = 0, minimumHeight: Int = 0) throws(ImageError) -> DecodedImage {
        var width: Int32 = 0
        var height: Int32 = 0
        var error = [CChar](repeating: 0, count: 160)
        let pixels = data.withUnsafeBytes { buffer in
            kiln_image_decode(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, Int32(minimumWidth), Int32(minimumHeight),
                              &width, &height, &error, error.count)
        }
        guard let pixels else {
            throw .decode(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        defer { kiln_image_free(pixels) }
        let count = Int(width) * Int(height) * 4
        return DecodedImage(width: Int(width), height: Int(height), pixels: Array(UnsafeBufferPointer(start: pixels, count: count)))
    }
}

/// A GIF's frames, each already composited over the ones before it, with how long each shows.
public struct AnimatedImage: Sendable {
    public let width: Int
    public let height: Int
    /// Straight-alpha RGBA8 rows, top first, one array a frame.
    public let frames: [[UInt8]]
    /// Seconds each frame shows.
    public let delays: [Double]

    /// Decodes every frame of a GIF, at most `maximumFrames` of them.
    public static func decodeGIF(_ data: Data, maximumFrames: Int = 240) throws(ImageError) -> AnimatedImage {
        var width: Int32 = 0
        var height: Int32 = 0
        var count: Int32 = 0
        var delays: UnsafeMutablePointer<Int32>?
        var error = [CChar](repeating: 0, count: 160)
        let pixels = data.withUnsafeBytes { buffer in
            kiln_gif_decode_frames(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count, Int32(maximumFrames), &width, &height, &count,
                                   &delays, &error, error.count)
        }
        guard let pixels, let delays else {
            throw .decode(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        defer {
            kiln_image_free(pixels)
            free(delays)
        }
        let frameBytes = Int(width) * Int(height) * 4
        let frames = (0..<Int(count)).map { index in Array(UnsafeBufferPointer(start: pixels + index * frameBytes, count: frameBytes)) }
        let times = (0..<Int(count)).map { Double(delays[$0]) / 1000 }
        return AnimatedImage(width: Int(width), height: Int(height), frames: frames, delays: times)
    }
}

/// Writes linear RGBA floats (a capture) as an 8-bit sRGB PNG, reference white as white and highlights clipped.
public enum PNGWriter {
    public static func write(linear pixels: [Float], width: Int, height: Int, to path: String) -> Bool {
        kiln_image_write_png(path, srgbBytes(linear: pixels, width: width, height: height), Int32(width), Int32(height))
    }

    /// The PNG file's bytes for a captured frame, for the clipboard or a file written elsewhere; nil when encoding fails.
    public static func encode(linear pixels: [Float], width: Int, height: Int) -> Data? {
        var length = 0
        guard let bytes = kiln_image_encode_png(srgbBytes(linear: pixels, width: width, height: height), Int32(width), Int32(height), &length)
        else { return nil }
        defer { free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// The PNG file's bytes for opaque or straight-alpha 8-bit RGBA rows; nil when encoding fails.
    public static func encode(rgba8 pixels: [UInt8], width: Int, height: Int) -> Data? {
        var length = 0
        guard pixels.count >= width * height * 4,
              let bytes = kiln_image_encode_png(pixels, Int32(width), Int32(height), &length) else { return nil }
        defer { free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    /// Linear light from a capture as opaque 8-bit sRGB, clipped to the reference white.
    private static func srgbBytes(linear pixels: [Float], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let value = min(max(pixels[index * 4 + channel], 0), 1)
                let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                bytes[index * 4 + channel] = UInt8((encoded * 255).rounded())
            }
            bytes[index * 4 + 3] = 255
        }
        return bytes
    }
}

/// An image to show: where it comes from and the smallest pixel size it is drawn at (the `TVImagePipeline` rule asks the
/// server for that size, with the focus oversample).
public struct ImageRequest: Hashable, Sendable {
    public let url: URL
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(url: URL, pixelWidth: Int, pixelHeight: Int) {
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Fetches, caches on disk, decodes and uploads artwork, keeping the most recently drawn textures in GPU memory up to a
/// budget and sharing one load between every view that asks for the same image.
@MainActor
public final class ImageStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private struct Entry {
        let texture: Texture
        var lastUse: UInt64
        var bytes: Int { texture.width * texture.height * 4 }
    }

    private let gpu: GPU
    private let fetch: Fetch
    private let diskDirectory: URL?
    private let budgetBytes: Int
    private var entries: [ImageRequest: Entry] = [:]
    private var inFlight: [ImageRequest: Task<Texture?, Never>] = [:]
    private var preloaded: [URL: Texture] = [:]
    private var clock: UInt64 = 0
    private var residentBytes = 0
    private var loadsSinceTrim = 0
    private let diskBudgetBytes: Int64

    /// `diskDirectory` keeps fetched files between launches (`$XDG_CACHE_HOME/crucible/images`), up to `diskBudgetBytes`;
    /// nil keeps them in memory only.
    public init(gpu: GPU, diskDirectory: URL?, budgetBytes: Int = 768 << 20, diskBudgetBytes: Int64 = 512 << 20, fetch: @escaping Fetch) {
        self.gpu = gpu
        self.fetch = fetch
        self.diskDirectory = diskDirectory
        self.budgetBytes = budgetBytes
        self.diskBudgetBytes = diskBudgetBytes
        if let diskDirectory {
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
            Self.trimDisk(diskDirectory, budget: diskBudgetBytes)
        }
    }

    /// Takes the disk cache down to three quarters of `budget` once it holds more, removing the files used longest ago
    /// first (a read marks a file used), off the main thread. Without it every poster and backdrop ever shown stayed on
    /// disk, at every size it was asked for.
    nonisolated static func trimDisk(_ directory: URL, budget: Int64) {
        Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            var listed: [(url: URL, used: Date, bytes: Int64)] = []
            var total: Int64 = 0
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                total += bytes
                listed.append((file, values.contentModificationDate ?? .distantPast, bytes))
            }
            guard total > budget else { return }
            for file in listed.sorted(by: { $0.used < $1.used }) {
                guard total > budget * 3 / 4 else { break }
                if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.bytes }
            }
        }
    }

    /// Serves `texture` for every request of `url`, whatever size it asks for (artwork drawn at runtime, fixtures).
    public func preload(_ texture: Texture, for url: URL) {
        preloaded[url] = texture
    }

    /// The texture if it is resident; marks it used.
    /// Forgets every decoded texture it holds; the ones views still show stay alive with them and the rest are freed.
    public func purgeMemory() {
        entries.removeAll()
        residentBytes = 0
    }

    public func cached(_ request: ImageRequest) -> Texture? {
        if let texture = preloaded[request.url] { return texture }
        guard var entry = entries[request] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[request] = entry
        return entry.texture
    }

    /// The texture for `request`, loading it if needed; nil when it cannot be fetched or decoded.
    public func load(_ request: ImageRequest) async -> Texture? {
        if let texture = cached(request) { return texture }
        if let running = inFlight[request] { return await running.value }
        let task = Task { [weak self] () -> Texture? in
            guard let self else { return nil }
            return await self.fetchDecodeAndUpload(request)
        }
        inFlight[request] = task
        let texture = await task.value
        inFlight[request] = nil
        return texture
    }

    private func fetchDecodeAndUpload(_ request: ImageRequest) async -> Texture? {
        let diskURL = diskDirectory?.appendingPathComponent(Self.cacheName(for: request.url))
        let fetch = self.fetch
        let uploader = gpu.uploader
        let loaded: LoadedImage? = await Task.detached(priority: .userInitiated) {
            var data: Data?
            if let diskURL {
                data = try? Data(contentsOf: diskURL)
                if data != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskURL.path) }
            }
            if data == nil {
                data = try? await fetch(request.url)
                if let data, let diskURL { try? data.write(to: diskURL, options: .atomic) }
            }
            guard let data, let decoded = try? ImageDecoder.decode(data, minimumWidth: request.pixelWidth, minimumHeight: request.pixelHeight) else {
                return nil
            }
            guard let uploader else { return .decoded(decoded) }
            let detached = decoded.pixels.withUnsafeBytes {
                uploader.rgba8(width: decoded.width, height: decoded.height, pixels: $0.baseAddress!, rowBytes: decoded.width * 4)
            }
            return detached.map(LoadedImage.uploaded)
        }.value
        guard let texture = loaded.flatMap(adopt) else { return nil }
        clock += 1
        let entry = Entry(texture: texture, lastUse: clock)
        entries[request] = entry
        residentBytes += entry.bytes
        evictIfNeeded()
        loadsSinceTrim += 1
        if loadsSinceTrim >= 500, let diskDirectory {
            loadsSinceTrim = 0
            Self.trimDisk(diskDirectory, budget: diskBudgetBytes)
        }
        return texture
    }

    /// The texture for a loaded image: adopted when the worker already uploaded it, uploaded here otherwise.
    private func adopt(_ loaded: LoadedImage) -> Texture? {
        switch loaded {
        case .uploaded(let detached):
            return gpu.adopt(detached)
        case .decoded(let decoded):
            guard let texture = try? gpu.texture(width: decoded.width, height: decoded.height, format: .rgba8, renderable: false) else { return nil }
            let uploaded = decoded.pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: decoded.width * 4) }
            return uploaded ? texture : nil
        }
    }

    /// Drops the least recently used textures past the budget. A view still holding one keeps it alive until it lets go.
    private func evictIfNeeded() {
        guard residentBytes > budgetBytes else { return }
        for (request, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard residentBytes > budgetBytes * 3 / 4 else { break }
            entries[request] = nil
            residentBytes -= entry.bytes
        }
    }

    public var residentByteCount: Int { residentBytes }

    /// A 128-bit file name for a URL: FNV-1a over the bytes forwards and backwards, so distinct URLs never share a file in
    /// practice.
    nonisolated static func cacheName(for url: URL) -> String {
        let bytes = Array(url.absoluteString.utf8)
        var forward: UInt64 = 0xCBF2_9CE4_8422_2325
        var backward: UInt64 = 0x6C62_272E_07BB_0142
        for byte in bytes {
            forward = (forward ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        for byte in bytes.reversed() {
            backward = (backward ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(forward, radix: 16) + "-" + String(backward, radix: 16)
    }

    /// Decodes and uploads image data already in hand (bundled art, test fixtures).
    public func texture(from data: Data) throws(ImageError) -> Texture {
        let decoded = try ImageDecoder.decode(data)
        guard let texture = try? gpu.texture(width: decoded.width, height: decoded.height, format: .rgba8, renderable: false) else { throw .upload }
        _ = decoded.pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: decoded.width * 4) }
        return texture
    }
}

import CKilnImage
import Foundation

/// Decoded straight-alpha RGBA8 rows, top first.
public struct DecodedImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
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
    private var clock: UInt64 = 0
    private var residentBytes = 0

    /// `diskDirectory` keeps fetched files between launches (`$XDG_CACHE_HOME/crucible/images`); nil keeps them in memory only.
    public init(gpu: GPU, diskDirectory: URL?, budgetBytes: Int = 768 << 20, fetch: @escaping Fetch) {
        self.gpu = gpu
        self.fetch = fetch
        self.diskDirectory = diskDirectory
        self.budgetBytes = budgetBytes
        if let diskDirectory { try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true) }
    }

    /// The texture if it is resident; marks it used.
    public func cached(_ request: ImageRequest) -> Texture? {
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
        let decoded: DecodedImage? = await Task.detached(priority: .userInitiated) {
            var data: Data?
            if let diskURL { data = try? Data(contentsOf: diskURL) }
            if data == nil {
                data = try? await fetch(request.url)
                if let data, let diskURL { try? data.write(to: diskURL, options: .atomic) }
            }
            guard let data else { return nil }
            return try? ImageDecoder.decode(data, minimumWidth: request.pixelWidth, minimumHeight: request.pixelHeight)
        }.value
        guard let decoded, let texture = try? gpu.texture(width: decoded.width, height: decoded.height, format: .rgba8, renderable: false) else { return nil }
        let uploaded = decoded.pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: decoded.width * 4) }
        guard uploaded else { return nil }
        clock += 1
        let entry = Entry(texture: texture, lastUse: clock)
        entries[request] = entry
        residentBytes += entry.bytes
        evictIfNeeded()
        return texture
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

import Foundation
import Kiln

/// The official marks of the services whose scores a title page shows (`BrandMark` on Apple), from the same artwork the
/// Apple apps draw: decoded once and kept for the life of the window's GPU.
@MainActor
public enum BrandMarks {
    private static var textures: [String: Texture] = [:]
    private static var unavailable: Set<String> = []

    /// The mark named `name` (`imdb`, `rottentomatoes-fresh`, `letterboxd-dark`), or nil when it is not bundled.
    public static func texture(_ name: String, gpu: GPU) -> Texture? {
        if let cached = textures[name] { return cached }
        guard !unavailable.contains(name) else { return nil }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Brand"),
              let data = try? Data(contentsOf: url),
              let decoded = try? ImageDecoder.decode(data),
              let texture = try? gpu.texture(width: decoded.width, height: decoded.height, format: .rgba8, renderable: false),
              decoded.pixels.withUnsafeBytes({ texture.upload($0.baseAddress!, rowBytes: decoded.width * 4) }) else {
            unavailable.insert(name)
            return nil
        }
        textures[name] = texture
        return texture
    }
}

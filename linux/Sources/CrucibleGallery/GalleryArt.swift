import CrucibleUI
import Foundation
import Kiln

/// Draws the gallery's posters, backdrops and portraits on the GPU at runtime, as the Apple TV gallery does, so the
/// design review needs neither assets nor a server. A URL such as `fixture://backdrop/salt-flats` picks the kind and
/// the seed; posters carry their title.
@MainActor
enum GalleryArt {
    struct Palette {
        let sky: [UInt32]
        let sun: UInt32
        let ridge: UInt32
    }

    static let palettes: [String: Palette] = [
        "salt-flats": Palette(sky: [0xFFFFFF, 0xF3E9D2, 0xE8D9B5], sun: 0xFFFDF4, ridge: 0xF7F1E1),
        "lighthouse": Palette(sky: [0x16314F, 0x3B5F82, 0xE9A25A], sun: 0xFFD08A, ridge: 0x0C1A2B),
        "orchard": Palette(sky: [0x2E4A2B, 0x7C9A4E, 0xF0C36A], sun: 0xFFE9A8, ridge: 0x1B2D18),
        "neon": Palette(sky: [0x1A0B33, 0x7A1F7A, 0xFF5C8A], sun: 0xFFB3CC, ridge: 0x0B0518),
        "ember": Palette(sky: [0x240A05, 0x8A2E10, 0xFF9F0A], sun: 0xFFD27A, ridge: 0x120503),
    ]

    static let order = ["lighthouse", "orchard", "neon", "ember", "salt-flats"]

    static func url(_ kind: String, _ seed: String) -> URL {
        URL(string: "fixture://\(kind)/\(seed)")!
    }

    static func palette(for seed: String) -> (Palette, UInt64) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        if let named = palettes[seed] { return (named, hash) }
        return (palettes[order[Int(hash % UInt64(order.count - 1))]]!, hash)
    }

    /// Renders every fixture the gallery names into `store`, at `pixelWidth` for its kind.
    static func preload(_ urls: [URL: String?], into store: ImageStore, gpu: GPU, scale: Float) {
        for (url, title) in urls {
            guard let host = url.host else { continue }
            let seed = String(url.path.dropFirst())
            let width: Int
            let height: Int
            switch host {
            case "backdrop":
                width = Int(1920 * scale)
                height = width * 9 / 16
            case "person":
                width = Int(360 * scale)
                height = width
            default:
                width = Int(300 * scale)
                height = width * 3 / 2
            }
            if let texture = render(kind: host, seed: seed, title: title, width: width, height: height, gpu: gpu) {
                store.preload(texture, for: url)
            }
        }
    }

    static func render(kind: String, seed: String, title: String?, width: Int, height: Int, gpu: GPU) -> Texture? {
        guard let texture = try? gpu.texture(width: width, height: height, format: .rgba16f, renderable: true) else { return nil }
        let (palette, hash) = palette(for: seed)
        let sky = palette.sky.map { Color(hex: $0) }
        let sun = Color(hex: palette.sun)
        let ridge = Color(hex: palette.ridge)
        let sunX: Float = kind == "backdrop" ? 0.72 : 0.3 + Float(hash % 40) / 100
        let sunY: Float = kind == "backdrop" ? 0.42 : 0.3 + Float((hash >> 8) % 20) / 100
        let phase = Float((hash >> 16) % 1000) / 100
        gpu.pass(into: texture, body: shader, uniforms: [
            .init("size", Float(width), Float(height)),
            .init("sky0", sky[0].red, sky[0].green, sky[0].blue),
            .init("sky1", sky[1].red, sky[1].green, sky[1].blue),
            .init("sky2", sky[2].red, sky[2].green, sky[2].blue),
            .init("sunColor", sun.red, sun.green, sun.blue),
            .init("ridgeColor", ridge.red, ridge.green, ridge.blue),
            .init("sunAt", sunX, sunY, kind == "backdrop" ? 0.16 : 0.12),
            .init("phase", phase),
            .init("portrait", kind == "person" ? 1 : 0),
        ])
        if let title, kind == "poster" {
            let painter = Painter(gpu: gpu, target: texture)
            let renderer = TextRenderer(gpu: gpu)
            var style = TextStyle(sizePixels: Double(width) * 0.13, weight: 800, opticalSize: 32, maxWidthPixels: Int(Double(width) * 0.84),
                                  maxLines: 3, alignment: .center)
            style.letterSpacingPixels = -Double(width) * 0.002
            if let label = try? renderer.texture(for: title.uppercased(), style: style) {
                let x = (Float(width) - Float(label.metrics.width)) / 2
                let y = Float(height) * 0.86 - Float(label.metrics.height)
                painter.gradient(Rect(x: 0, y: Float(height) * 0.5, width: Float(width), height: Float(height) * 0.5), vertical: true,
                                 stops: [(0, Color.shade(0)), (1, Color.shade(0.55))])
                painter.text(label.texture, x: x, y: y, color: Color(hex: 0xFFF6EA))
                painter.flush()
            }
        }
        return texture
    }

    static let shader = """
    vec2 uv = gl_FragCoord.xy / size;
    vec3 c = uv.y < 0.5 ? mix(sky0, sky1, uv.y * 2.0) : mix(sky1, sky2, (uv.y - 0.5) * 2.0);
    vec2 sunCentre = sunAt.xy * size;
    float r = sunAt.z * size.y;
    float d = length(gl_FragCoord.xy - sunCentre);
    c += sunColor * 0.45 * exp(-d / (r * 2.2));
    c = mix(c, sunColor, smoothstep(r, r - 1.5, d));
    float x = uv.x * 6.2831;
    float far = 0.62 + 0.05 * sin(x * 1.3 + phase) + 0.03 * sin(x * 3.1 + phase * 2.0);
    float near = 0.74 + 0.06 * sin(x * 0.9 + phase * 1.7) + 0.025 * sin(x * 4.3 + phase);
    c = mix(c, mix(ridgeColor, sky1, 0.45), smoothstep(far - 0.002, far + 0.002, uv.y));
    c = mix(c, ridgeColor, smoothstep(near - 0.002, near + 0.002, uv.y));
    if (portrait > 0.5) {
        vec2 head = vec2(0.5, 0.42) * size;
        float face = length((gl_FragCoord.xy - head) / vec2(0.19, 0.23) / size.y);
        float shoulders = length((gl_FragCoord.xy - vec2(0.5, 1.02) * size) / vec2(0.42, 0.3) / size.y);
        float body = min(face, shoulders);
        c = mix(c, ridgeColor * 0.9 + sunColor * 0.08, smoothstep(1.0, 0.985, body));
    }
    color = vec4(c, 1.0);
    """
}

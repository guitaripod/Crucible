import CKilnGPU
import Foundation
import Glibc

/// A texture on Kiln's GPU: half-float render targets for composition, RGBA8 for artwork, R8 for glyphs.
@MainActor
public final class Texture {
    public enum Format: Sendable {
        case rgba16f, rgba8, r8

        var raw: kiln_format {
            switch self {
            case .rgba16f: KILN_FORMAT_RGBA16F
            case .rgba8: KILN_FORMAT_RGBA8
            case .r8: KILN_FORMAT_R8
            }
        }
    }

    let handle: OpaquePointer
    let gpu: GPU
    public let width: Int
    public let height: Int
    public let format: Format

    /// Whether the texels are sRGB encoded (8-bit artwork) rather than linear light (render targets, video).
    public var isSRGB: Bool { format == .rgba8 }

    init(handle: OpaquePointer, gpu: GPU, format: Format) {
        self.handle = handle
        self.gpu = gpu
        self.format = format
        width = Int(kiln_tex_width(handle))
        height = Int(kiln_tex_height(handle))
    }

    /// Whether the GPU has finished the picture a video player last drew into this texture. Drawing the texture before
    /// that makes the window's frame wait for it, a decoded 4K picture's worth of GPU time.
    public var isVideoDrawn: Bool { kiln_tex_video_drawn(gpu.handle, handle) }

    public func upload(_ pixels: UnsafeRawPointer, rowBytes: Int) -> Bool {
        FrameTrace.uploads += 1
        return kiln_tex_upload(gpu.handle, handle, pixels, rowBytes)
    }

    /// Linear RGBA floats, top row first.
    public func download() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        _ = kiln_tex_download(gpu.handle, handle, &pixels)
        return pixels
    }

    /// Hands the image to an external Vulkan user (mpv) and returns its handles; `release` gives it back.
    public func holdForVulkan() -> (image: UnsafeMutableRawPointer, view: UnsafeMutableRawPointer, format: UInt32, layout: UInt32)? {
        var image: UnsafeMutableRawPointer?
        var view: UnsafeMutableRawPointer?
        var format: UInt32 = 0
        var layout: UInt32 = 0
        guard kiln_tex_hold_vulkan(gpu.handle, handle, &image, &view, &format, &layout), let image, let view else { return nil }
        return (image, view, format, layout)
    }

    /// Starts an asynchronous copy to the host; `Readback.poll` returns the pixels once it landed.
    public func beginReadback() -> Readback? {
        kiln_tex_readback_begin(gpu.handle, handle).map { Readback(handle: $0, gpu: gpu) }
    }

    public func releaseFromVulkan(layout: UInt32) {
        kiln_tex_release_vulkan(gpu.handle, handle, layout)
    }

    isolated deinit {
        kiln_tex_destroy(gpu.handle, handle)
    }
}

/// Creates and fills sampled textures on any thread of a thread-safe device.
public struct TextureUploader: @unchecked Sendable {
    let gpu: OpaquePointer

    /// Frees a texture this uploader made that will not be adopted after all.
    public func discard(_ detached: DetachedTexture) {
        kiln_tex_destroy(gpu, detached.handle)
    }

    /// An sRGB RGBA8 texture holding `pixels`, ready to adopt on the main thread.
    public func rgba8(width: Int, height: Int, pixels: UnsafeRawPointer, rowBytes: Int) -> DetachedTexture? {
        guard let raw = kiln_tex_create(gpu, Int32(width), Int32(height), KILN_FORMAT_RGBA8, false) else { return nil }
        guard kiln_tex_upload(gpu, raw, pixels, rowBytes) else {
            kiln_tex_destroy(gpu, raw)
            return nil
        }
        return DetachedTexture(handle: raw, format: .rgba8)
    }
}

/// A texture an uploader made off the main thread, owned by nobody until `GPU.adopt` takes it.
public struct DetachedTexture: @unchecked Sendable {
    let handle: OpaquePointer
    let format: Texture.Format
}

/// A texture copy on its way to the host.
@MainActor
public final class Readback {
    let handle: OpaquePointer
    let gpu: GPU
    public let width: Int
    public let height: Int

    init(handle: OpaquePointer, gpu: GPU) {
        self.handle = handle
        self.gpu = gpu
        width = Int(kiln_readback_width(handle))
        height = Int(kiln_readback_height(handle))
    }

    /// Linear RGBA floats, top row first, once the copy finished; nil while it is in flight.
    public func poll() -> [Float]? {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        return kiln_readback_poll(gpu.handle, handle, &pixels) ? pixels : nil
    }

    isolated deinit {
        kiln_readback_destroy(gpu.handle, handle)
    }
}

/// Kiln's GPU: libplacebo on a Vulkan device shared with mpv, presenting an FP16 scRGB swapchain. Passes are GLSL
/// bodies that write `color`; positions are `gl_FragCoord` in target pixels with the origin at the top left, and
/// colours are linear BT.709 where 1.0 is the UI's reference white (203 cd/m2).
@MainActor
public final class GPU {
    public struct Sampler {
        public let name: String
        public let texture: Texture
        public let nearest: Bool

        public init(_ name: String, _ texture: Texture, nearest: Bool = false) {
            self.name = name
            self.texture = texture
            self.nearest = nearest
        }
    }

    public struct Uniform {
        public let name: String
        public let values: [Float]

        public init(_ name: String, _ values: Float...) {
            self.name = name
            self.values = values
        }
    }

    public struct VulkanHandles {
        public let raw: kiln_vulkan_handles
    }

    let handle: OpaquePointer
    public let deviceName: String

    public init(display: OpaquePointer?, surface: OpaquePointer?) throws(RenderError) {
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = kiln_gpu_create(display, surface, &error, error.count) else {
            throw .device(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        self.handle = handle
        deviceName = String(cString: kiln_gpu_device_name(handle))
    }

    /// The device with a FIFO swapchain on an X11 window (`xcbConnection` is its `xcb_connection_t`).
    public init(xcbConnection: UnsafeMutableRawPointer?, window: UInt32) throws(RenderError) {
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = kiln_gpu_create_xcb(xcbConnection, window, &error, error.count) else {
            throw .device(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        self.handle = handle
        deviceName = String(cString: kiln_gpu_device_name(handle))
    }

    public var vulkanHandles: VulkanHandles { VulkanHandles(raw: kiln_gpu_vulkan_handles(handle)) }

    /// Multiplies the light the swapchain shows by `gain`, and presents SDR instead of scRGB when `sdr` (the compositor's
    /// output is SDR and it wants SDR buffers).
    public func setOutput(gain: Float, sdr: Bool) {
        kiln_gpu_set_output(handle, gain, sdr)
    }

    public func resize(width: Int, height: Int) -> (width: Int, height: Int)? {
        var w = Int32(width)
        var h = Int32(height)
        guard kiln_gpu_resize(handle, &w, &h) else { return nil }
        return (Int(w), Int(h))
    }

    /// Makes sampled textures on other threads when the device allows it (Vulkan does), so decoded artwork is uploaded
    /// beside decoding instead of on the main thread.
    public var uploader: TextureUploader? { kiln_gpu_thread_safe(handle) ? TextureUploader(gpu: handle) : nil }

    /// Takes over a texture an uploader made; it is drawn and released on the main thread from here on.
    public func adopt(_ detached: DetachedTexture) -> Texture {
        Texture(handle: detached.handle, gpu: self, format: detached.format)
    }

    public func texture(width: Int, height: Int, format: Texture.Format, renderable: Bool) throws(RenderError) -> Texture {
        guard let raw = kiln_tex_create(handle, Int32(width), Int32(height), format.raw, renderable) else {
            throw .texture(width, height)
        }
        return Texture(handle: raw, gpu: self, format: format)
    }

    @discardableResult
    public func pass(into target: Texture, header: String = "", body: String, samplers: [Sampler] = [], uniforms: [Uniform] = [],
                     rect: (x0: Float, y0: Float, x1: Float, y1: Float)? = nil, blend: Bool = false) -> Bool {
        FrameTrace.passes += 1
        let started = Window.now()
        defer { FrameTrace.passTime += Window.now() - started }
        let names = samplers.map { strdup($0.name) } + uniforms.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        let rawSamplers = samplers.enumerated().map { index, sampler in
            kiln_sampler(name: names[index], tex: sampler.texture.handle, nearest: sampler.nearest)
        }
        let rawUniforms = uniforms.enumerated().map { index, uniform in
            var value: (Float, Float, Float, Float) = (0, 0, 0, 0)
            withUnsafeMutableBytes(of: &value) { buffer in
                for (component, number) in uniform.values.prefix(4).enumerated() {
                    buffer.storeBytes(of: number, toByteOffset: component * MemoryLayout<Float>.size, as: Float.self)
                }
            }
            return kiln_uniform(name: names[samplers.count + index], components: Int32(uniform.values.count), value: value)
        }
        return header.withCString { headerPointer in
            body.withCString { bodyPointer in
                if let rect {
                    let area: [Float] = [rect.x0, rect.y0, rect.x1, rect.y1]
                    return kiln_gpu_pass(handle, target.handle, headerPointer, bodyPointer, rawSamplers, Int32(rawSamplers.count),
                                         rawUniforms, Int32(rawUniforms.count), area, blend)
                }
                return kiln_gpu_pass(handle, target.handle, headerPointer, bodyPointer, rawSamplers, Int32(rawSamplers.count),
                                     rawUniforms, Int32(rawUniforms.count), nil, blend)
            }
        }
    }

    /// One float vertex attribute of `draw`, read by `name` in the shader.
    public struct Attribute: Sendable {
        public let name: String
        public let components: Int

        public init(_ name: String, components: Int) {
            self.name = name
            self.components = components
        }
    }

    /// Draws `vertexCount` vertices as triangles into `target` in one pass: `vertices` holds each vertex's `attributes` in
    /// order, the first the position in target pixels, the others read by name in `body`, which writes `color` as in
    /// `pass`. Many primitives drawn this way cost one pass.
    @discardableResult
    public func draw(into target: Texture, header: String = "", body: String, samplers: [Sampler], attributes: [Attribute],
                     vertices: UnsafePointer<Float>, vertexCount: Int, blend: Bool = true) -> Bool {
        FrameTrace.passes += 1
        let started = Window.now()
        defer { FrameTrace.passTime += Window.now() - started }
        let names = samplers.map { strdup($0.name) } + attributes.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        let rawSamplers = samplers.enumerated().map { index, sampler in
            kiln_sampler(name: names[index], tex: sampler.texture.handle, nearest: sampler.nearest)
        }
        let rawAttributes = attributes.enumerated().map { index, attribute in
            kiln_attribute(name: names[samplers.count + index], components: Int32(attribute.components))
        }
        return header.withCString { headerPointer in
            body.withCString { bodyPointer in
                kiln_gpu_draw(handle, target.handle, headerPointer, bodyPointer, rawSamplers, Int32(rawSamplers.count), rawAttributes,
                              Int32(rawAttributes.count), vertices, Int32(vertexCount), blend)
            }
        }
    }

    /// Distinct 1x1 textures for sampler slots a pass declares but does not use (libplacebo binds each texture once per
    /// pass), as many as `count`, made on first use.
    public func blankTextures(_ count: Int) -> [Texture] {
        while blanks.count < count {
            guard let texture = try? texture(width: 1, height: 1, format: .r8, renderable: false) else { break }
            var zero: UInt8 = 0
            _ = texture.upload(&zero, rowBytes: 1)
            blanks.append(texture)
        }
        return Array(blanks.prefix(count))
    }

    private var blanks: [Texture] = []

    @discardableResult
    /// Presents the top-left `width` by `height` pixels of `source`.
    public func present(_ source: Texture, width: Int, height: Int) -> Bool {
        kiln_gpu_present(handle, source.handle, Int32(width), Int32(height))
    }

    /// Tells the compositor the brightest the window's content gets, in cd/m² on the scRGB scale (`kiln_gpu_set_content_peak`).
    public func setContentPeak(nits: Float) {
        kiln_gpu_set_content_peak(handle, nits)
    }

    public func takeGPUMilliseconds() -> Double {
        kiln_gpu_take_gpu_ms(handle)
    }

    public func finish() {
        kiln_gpu_finish(handle)
    }

    /// Keeps compiled shaders in `url` between launches.
    @discardableResult
    public func useShaderCache(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return kiln_gpu_use_shader_cache(handle, url.path)
    }

    /// Writes shaders compiled since the last save.
    public func saveShaderCache() {
        _ = kiln_gpu_save_shader_cache(handle)
    }

    /// Lets go of the window surface before its Wayland connection closes.
    public func releaseSurface() {
        kiln_gpu_release_surface(handle)
    }

    isolated deinit {
        kiln_gpu_destroy(handle)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case device(String)
    case texture(Int, Int)

    public var description: String {
        switch self {
        case .device(let reason): "GPU device failed: \(reason)"
        case .texture(let width, let height): "texture \(width)x\(height) failed"
        }
    }
}

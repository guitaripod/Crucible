import CKilnGPU
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
    unowned let gpu: GPU
    public let width: Int
    public let height: Int

    init(handle: OpaquePointer, gpu: GPU) {
        self.handle = handle
        self.gpu = gpu
        width = Int(kiln_tex_width(handle))
        height = Int(kiln_tex_height(handle))
    }

    public func upload(_ pixels: UnsafeRawPointer, rowBytes: Int) -> Bool {
        kiln_tex_upload(gpu.handle, handle, pixels, rowBytes)
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

    public func releaseFromVulkan(layout: UInt32) {
        kiln_tex_release_vulkan(gpu.handle, handle, layout)
    }

    isolated deinit {
        kiln_tex_destroy(gpu.handle, handle)
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

    public var vulkanHandles: VulkanHandles { VulkanHandles(raw: kiln_gpu_vulkan_handles(handle)) }

    public func resize(width: Int, height: Int) -> (width: Int, height: Int)? {
        var w = Int32(width)
        var h = Int32(height)
        guard kiln_gpu_resize(handle, &w, &h) else { return nil }
        return (Int(w), Int(h))
    }

    public func texture(width: Int, height: Int, format: Texture.Format, renderable: Bool) throws(RenderError) -> Texture {
        guard let raw = kiln_tex_create(handle, Int32(width), Int32(height), format.raw, renderable) else {
            throw .texture(width, height)
        }
        return Texture(handle: raw, gpu: self)
    }

    @discardableResult
    public func pass(into target: Texture, header: String = "", body: String, samplers: [Sampler] = [], uniforms: [Uniform] = [],
                     rect: (x0: Float, y0: Float, x1: Float, y1: Float)? = nil, blend: Bool = false) -> Bool {
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

    @discardableResult
    public func present(_ source: Texture) -> Bool {
        kiln_gpu_present(handle, source.handle)
    }

    public func takeGPUMilliseconds() -> Double {
        kiln_gpu_take_gpu_ms(handle)
    }

    public func finish() {
        kiln_gpu_finish(handle)
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

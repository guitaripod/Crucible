import CKiln
import CMPV
import Foundation
import Kiln

/// libmpv through its OpenGL render API, drawing each frame into a Kiln render target as PQ BT.2020 (absolute
/// luminance, no tone mapping) so Kiln can composite it in linear light.
@MainActor
final class MPVTexture {
    let handle: OpaquePointer
    private var renderContext: OpaquePointer?

    /// `MPV_RENDER_PARAM_BACKEND` in the gpu-next render API patch series; upstream libmpv ignores unknown parameters.
    static let backendParameter = mpv_render_param_type(rawValue: 21)

    init(options: [String: String], backend: String? = ProcessInfo.processInfo.environment["MPV_RENDER_BACKEND"]) throws {
        guard let handle = mpv_create() else { throw SpikeFailure("mpv_create failed") }
        self.handle = handle
        for (name, value) in options {
            let status = mpv_set_option_string(handle, name, value)
            guard status >= 0 else { throw SpikeFailure("option \(name)=\(value): \(String(cString: mpv_error_string(status)))") }
        }
        guard mpv_initialize(handle) >= 0 else { throw SpikeFailure("mpv_initialize failed") }
        var initParameters = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name, let address = eglGetProcAddress(name) else { return nil }
                return unsafeBitCast(address, to: UnsafeMutableRawPointer.self)
            },
            get_proc_address_ctx: nil
        )
        let backendName = strdup(backend ?? "")
        defer { free(backendName) }
        let created: Int32 = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParameters) { initPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                ]
                if backend != nil {
                    parameters.append(mpv_render_param(type: Self.backendParameter, data: UnsafeMutableRawPointer(backendName)))
                }
                parameters.append(mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil))
                return mpv_render_context_create(&renderContext, handle, &parameters)
            }
        }
        guard created >= 0 else { throw SpikeFailure("render context: \(String(cString: mpv_error_string(created)))") }
    }

    func command(_ arguments: [String]) throws {
        var pointers = arguments.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        let status = pointers.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { mpv_command(handle, $0) }
        }
        guard status >= 0 else { throw SpikeFailure("command \(arguments): \(String(cString: mpv_error_string(status)))") }
    }

    func property(_ name: String) -> String? {
        guard let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    /// Waits for mpv to report the named event, giving up after `seconds`.
    func wait(for event: mpv_event_id, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let next = mpv_wait_event(handle, 0.1) else { continue }
            if next.pointee.event_id == event { return true }
            if next.pointee.event_id == MPV_EVENT_SHUTDOWN { return false }
        }
        return false
    }

    func render(into target: RenderTarget) {
        guard let renderContext else { return }
        _ = mpv_render_context_update(renderContext)
        var fbo = mpv_opengl_fbo(fbo: Int32(target.framebuffer), w: Int32(target.width), h: Int32(target.height), internal_format: Int32(GL_RGBA16F))
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(renderContext, &parameters)
            }
        }
    }

    func close() {
        if let renderContext { mpv_render_context_free(renderContext) }
        mpv_terminate_destroy(handle)
    }
}

struct SpikeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

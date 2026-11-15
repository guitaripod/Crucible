import CKiln

/// An OpenGL 4.6 core context on the window's surface, with a 16-bit float colour buffer so the surface can carry scRGB
/// values past 1.0, falling back to 10-bit when the driver offers no float configuration.
@MainActor
public final class EGLWindowContext {
    public enum Format: Sendable { case float16, rgb10a2 }

    public let display: EGLDisplay
    public let context: EGLContext
    public let surface: EGLSurface
    public let format: Format
    private let nativeWindow: OpaquePointer

    public init?(wlDisplay: OpaquePointer, wlSurface: OpaquePointer, width: Int, height: Int) {
        guard let display = eglGetPlatformDisplay(EGLenum(EGL_PLATFORM_WAYLAND_KHR), UnsafeMutableRawPointer(wlDisplay), nil) else { return nil }
        var major: EGLint = 0
        var minor: EGLint = 0
        guard eglInitialize(display, &major, &minor) == EGL_TRUE, eglBindAPI(EGLenum(EGL_OPENGL_API)) == EGL_TRUE else { return nil }
        guard let (config, format) = Self.chooseConfig(display) else { return nil }
        let contextAttributes: [EGLint] = [
            EGLint(EGL_CONTEXT_MAJOR_VERSION), 4,
            EGLint(EGL_CONTEXT_MINOR_VERSION), 6,
            EGLint(EGL_CONTEXT_OPENGL_PROFILE_MASK), EGLint(EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT),
            EGLint(EGL_NONE),
        ]
        guard let context = eglCreateContext(display, config, nil, contextAttributes) else { return nil }
        guard let window = wl_egl_window_create(wlSurface, Int32(width), Int32(height)) else { return nil }
        guard let surface = eglCreatePlatformWindowSurface(display, config, UnsafeMutableRawPointer(window), nil) else { return nil }
        guard eglMakeCurrent(display, surface, surface, context) == EGL_TRUE else { return nil }
        eglSwapInterval(display, 0)
        self.display = display
        self.context = context
        self.surface = surface
        self.format = format
        self.nativeWindow = window
    }

    public func resize(width: Int, height: Int) {
        wl_egl_window_resize(nativeWindow, Int32(width), Int32(height), 0, 0)
    }

    public func swap() {
        eglSwapBuffers(display, surface)
    }

    public var renderer: String {
        guard let name = glGetString(GLenum(GL_RENDERER)) else { return "unknown" }
        return String(cString: name)
    }

    public var vendor: String {
        guard let name = eglQueryString(display, EGL_VENDOR) else { return "unknown" }
        return String(cString: name)
    }

    private static func chooseConfig(_ display: EGLDisplay) -> (EGLConfig, Format)? {
        let floatAttributes: [EGLint] = [
            EGLint(EGL_SURFACE_TYPE), EGLint(EGL_WINDOW_BIT),
            EGLint(EGL_RENDERABLE_TYPE), EGLint(EGL_OPENGL_BIT),
            EGLint(EGL_COLOR_COMPONENT_TYPE_EXT), EGLint(EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT),
            EGLint(EGL_RED_SIZE), 16, EGLint(EGL_GREEN_SIZE), 16, EGLint(EGL_BLUE_SIZE), 16, EGLint(EGL_ALPHA_SIZE), 16,
            EGLint(EGL_NONE),
        ]
        if let config = firstConfig(display, floatAttributes) { return (config, .float16) }
        let tenBitAttributes: [EGLint] = [
            EGLint(EGL_SURFACE_TYPE), EGLint(EGL_WINDOW_BIT),
            EGLint(EGL_RENDERABLE_TYPE), EGLint(EGL_OPENGL_BIT),
            EGLint(EGL_RED_SIZE), 10, EGLint(EGL_GREEN_SIZE), 10, EGLint(EGL_BLUE_SIZE), 10, EGLint(EGL_ALPHA_SIZE), 2,
            EGLint(EGL_NONE),
        ]
        if let config = firstConfig(display, tenBitAttributes) { return (config, .rgb10a2) }
        return nil
    }

    private static func firstConfig(_ display: EGLDisplay, _ attributes: [EGLint]) -> EGLConfig? {
        var config: EGLConfig?
        var count: EGLint = 0
        guard eglChooseConfig(display, attributes, &config, 1, &count) == EGL_TRUE, count > 0 else { return nil }
        return config
    }
}

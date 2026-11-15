import CKiln

/// An OpenGL 4.6 core context on the first GPU with no window, for golden images, tests and video checks. Rendering goes
/// into `RenderTarget`s only.
@MainActor
public final class EGLHeadlessContext {
    public let display: EGLDisplay
    public let context: EGLContext

    private typealias QueryDevices = @convention(c) (EGLint, UnsafeMutablePointer<EGLDeviceEXT?>?, UnsafeMutablePointer<EGLint>?) -> EGLBoolean

    public nonisolated(unsafe) static var failure = ""

    public init?() {
        guard let address = eglGetProcAddress("eglQueryDevicesEXT") else { Self.failure = "no eglQueryDevicesEXT"; return nil }
        let queryDevices = unsafeBitCast(address, to: QueryDevices.self)
        var devices = [EGLDeviceEXT?](repeating: nil, count: 8)
        var count: EGLint = 0
        guard queryDevices(EGLint(devices.count), &devices, &count) == EGL_TRUE, count > 0 else { Self.failure = "no devices"; return nil }
        guard let display = eglGetPlatformDisplay(EGLenum(EGL_PLATFORM_DEVICE_EXT), devices[0], nil) else { Self.failure = "no device display"; return nil }
        var major: EGLint = 0
        var minor: EGLint = 0
        guard eglInitialize(display, &major, &minor) == EGL_TRUE, eglBindAPI(EGLenum(EGL_OPENGL_API)) == EGL_TRUE else {
            Self.failure = "initialize failed \(eglGetError())"
            return nil
        }
        let configAttributes: [EGLint] = [EGLint(EGL_RENDERABLE_TYPE), EGLint(EGL_OPENGL_BIT), EGLint(EGL_SURFACE_TYPE), EGLint(EGL_PBUFFER_BIT), EGLint(EGL_NONE)]
        var config: EGLConfig?
        var configs: EGLint = 0
        if eglChooseConfig(display, configAttributes, &config, 1, &configs) != EGL_TRUE || configs == 0 { config = nil }
        let contextAttributes: [EGLint] = [
            EGLint(EGL_CONTEXT_MAJOR_VERSION), 4,
            EGLint(EGL_CONTEXT_MINOR_VERSION), 6,
            EGLint(EGL_CONTEXT_OPENGL_PROFILE_MASK), EGLint(EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT),
            EGLint(EGL_NONE),
        ]
        guard let context = eglCreateContext(display, config, nil, contextAttributes) else { Self.failure = "context failed \(eglGetError())"; return nil }
        guard eglMakeCurrent(display, nil, nil, context) == EGL_TRUE else { Self.failure = "make current failed \(eglGetError())"; return nil }
        self.display = display
        self.context = context
    }

    public var renderer: String {
        guard let name = glGetString(GLenum(GL_RENDERER)) else { return "unknown" }
        return String(cString: name)
    }
}

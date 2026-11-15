import CKiln

/// A linked GLSL program with its uniform locations looked up once.
@MainActor
public final class ShaderProgram {
    public let id: GLuint
    private var locations: [String: GLint] = [:]

    public init(vertex: String, fragment: String) throws(RenderError) {
        let vertexShader = try Self.compile(vertex, type: GLenum(GL_VERTEX_SHADER))
        let fragmentShader = try Self.compile(fragment, type: GLenum(GL_FRAGMENT_SHADER))
        let program = glCreateProgram()
        glAttachShader(program, vertexShader)
        glAttachShader(program, fragmentShader)
        glLinkProgram(program)
        glDeleteShader(vertexShader)
        glDeleteShader(fragmentShader)
        var linked: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
        guard linked == GL_TRUE else { throw .link(Self.programLog(program)) }
        id = program
    }

    public func use() { glUseProgram(id) }

    public func location(_ name: String) -> GLint {
        if let known = locations[name] { return known }
        let found = glGetUniformLocation(id, name)
        locations[name] = found
        return found
    }

    public func set(_ name: String, _ value: Float) { glUniform1f(location(name), value) }
    public func set(_ name: String, _ x: Float, _ y: Float) { glUniform2f(location(name), x, y) }
    public func set(_ name: String, _ x: Float, _ y: Float, _ z: Float, _ w: Float) { glUniform4f(location(name), x, y, z, w) }
    public func set(_ name: String, sampler unit: Int32) { glUniform1i(location(name), unit) }

    private static func compile(_ source: String, type: GLenum) throws(RenderError) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { pointer in
            var text: UnsafePointer<GLchar>? = pointer
            glShaderSource(shader, 1, &text, nil)
        }
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
        guard compiled == GL_TRUE else { throw .compile(shaderLog(shader)) }
        return shader
    }

    private static func shaderLog(_ shader: GLuint) -> String {
        var buffer = [GLchar](repeating: 0, count: 4096)
        glGetShaderInfoLog(shader, GLsizei(buffer.count), nil, &buffer)
        return String(cString: buffer)
    }

    private static func programLog(_ program: GLuint) -> String {
        var buffer = [GLchar](repeating: 0, count: 4096)
        glGetProgramInfoLog(program, GLsizei(buffer.count), nil, &buffer)
        return String(cString: buffer)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case compile(String)
    case link(String)
    case incompleteFramebuffer(GLenum)

    public var description: String {
        switch self {
        case .compile(let log): "shader compile failed: \(log)"
        case .link(let log): "program link failed: \(log)"
        case .incompleteFramebuffer(let status): "framebuffer incomplete: \(status)"
        }
    }
}

/// A half-float colour texture with its framebuffer, the unit every Kiln pass reads and writes.
@MainActor
public final class RenderTarget {
    public let framebuffer: GLuint
    public let texture: GLuint
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws(RenderError) {
        var texture: GLuint = 0
        glCreateTextures(GLenum(GL_TEXTURE_2D), 1, &texture)
        glTextureStorage2D(texture, 1, GLenum(GL_RGBA16F), GLsizei(width), GLsizei(height))
        glTextureParameteri(texture, GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTextureParameteri(texture, GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTextureParameteri(texture, GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTextureParameteri(texture, GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        var framebuffer: GLuint = 0
        glCreateFramebuffers(1, &framebuffer)
        glNamedFramebufferTexture(framebuffer, GLenum(GL_COLOR_ATTACHMENT0), texture, 0)
        let status = glCheckNamedFramebufferStatus(framebuffer, GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw .incompleteFramebuffer(status) }
        self.texture = texture
        self.framebuffer = framebuffer
        self.width = width
        self.height = height
    }

    public func bindForDrawing() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
    }

    public func bind(unit: GLuint) {
        glBindTextureUnit(unit, texture)
    }

    /// Reads the target back as linear RGBA floats, bottom row first.
    public func readPixels() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        glGetTextureImage(texture, 0, GLenum(GL_RGBA), GLenum(GL_FLOAT), GLsizei(pixels.count * MemoryLayout<Float>.size), &pixels)
        return pixels
    }

    public func release() {
        var framebuffer = framebuffer
        var texture = texture
        glDeleteFramebuffers(1, &framebuffer)
        glDeleteTextures(1, &texture)
    }
}

/// GPU time spent between `begin` and `end`, read a frame later so the pipeline never stalls on it.
@MainActor
public final class GPUTimer {
    private var queries: [GLuint] = [0, 0]
    private var frame = 0
    public private(set) var lastMilliseconds: Double?

    public init() {
        glCreateQueries(GLenum(GL_TIME_ELAPSED), 2, &queries)
    }

    public func begin() {
        glBeginQuery(GLenum(GL_TIME_ELAPSED), queries[frame % 2])
    }

    public func end() {
        glEndQuery(GLenum(GL_TIME_ELAPSED))
        frame += 1
        guard frame >= 2 else { return }
        let previous = queries[frame % 2]
        var available: GLint = 0
        glGetQueryObjectiv(previous, GLenum(GL_QUERY_RESULT_AVAILABLE), &available)
        guard available == GL_TRUE else { return }
        var nanoseconds: GLuint64 = 0
        glGetQueryObjectui64v(previous, GLenum(GL_QUERY_RESULT), &nanoseconds)
        lastMilliseconds = Double(nanoseconds) / 1_000_000
    }
}

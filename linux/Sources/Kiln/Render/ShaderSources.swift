/// GLSL for Kiln's passes. Every pass draws one full-screen triangle; colours are linear scRGB where 1.0 is 80 cd/m2 and
/// the UI's white sits at `referenceWhite`.
public enum ShaderSources {
    public static let fullscreenVertex = """
    #version 460 core
    out vec2 uv;
    void main() {
        vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
        uv = corner;
        gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    static let kawaseDown = """
    #version 460 core
    in vec2 uv;
    out vec4 color;
    uniform sampler2D source;
    uniform vec2 halfPixel;
    uniform float offset;
    void main() {
        vec2 d = halfPixel * offset;
        vec4 sum = texture(source, uv) * 4.0;
        sum += texture(source, uv - d);
        sum += texture(source, uv + d);
        sum += texture(source, uv + vec2(d.x, -d.y));
        sum += texture(source, uv - vec2(d.x, -d.y));
        color = sum / 8.0;
    }
    """

    static let kawaseUp = """
    #version 460 core
    in vec2 uv;
    out vec4 color;
    uniform sampler2D source;
    uniform vec2 halfPixel;
    uniform float offset;
    void main() {
        vec2 d = halfPixel * offset;
        vec4 sum = texture(source, uv + vec2(-d.x * 2.0, 0.0));
        sum += texture(source, uv + vec2(-d.x, d.y)) * 2.0;
        sum += texture(source, uv + vec2(0.0, d.y * 2.0));
        sum += texture(source, uv + vec2(d.x, d.y)) * 2.0;
        sum += texture(source, uv + vec2(d.x * 2.0, 0.0));
        sum += texture(source, uv + vec2(d.x, -d.y)) * 2.0;
        sum += texture(source, uv + vec2(0.0, -d.y * 2.0));
        sum += texture(source, uv + vec2(-d.x, -d.y)) * 2.0;
        color = sum / 12.0;
    }
    """

    static let copy = """
    #version 460 core
    in vec2 uv;
    out vec4 color;
    uniform sampler2D source;
    void main() {
        color = texture(source, uv);
    }
    """

    static let liquidGlass = """
    #version 460 core
    in vec2 uv;
    out vec4 color;
    uniform sampler2D scene;
    uniform sampler2D frost;
    uniform sampler2D tiny;
    uniform vec2 size;
    uniform vec4 shapeA;
    uniform vec4 shapeB;
    uniform vec2 radii;
    uniform float blend;
    uniform vec4 pill;
    uniform float pillRadius;
    uniform float rimWidth;
    uniform float refraction;
    uniform float dispersion;
    uniform vec2 light;
    uniform float press;
    uniform float clearness;
    uniform float referenceWhite;
    uniform float shadowOpacity;
    uniform vec2 shadowOffset;
    uniform float shadowRadius;

    float roundedBox(vec2 p, vec2 halfSize, float radius) {
        vec2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    float smoothUnion(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-4), 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    float field(vec2 p) {
        float a = roundedBox(p - shapeA.xy, shapeA.zw, radii.x);
        if (shapeB.z <= 0.0) return a;
        float b = roundedBox(p - shapeB.xy, shapeB.zw, radii.y);
        return smoothUnion(a, b, blend);
    }

    vec3 gradientAt(vec2 p) {
        vec2 e = vec2(max(rimWidth * 0.12, 1.0), 0.0);
        vec2 g = vec2(field(p + e.xy) - field(p - e.xy), field(p + e.yx) - field(p - e.yx)) / (2.0 * e.x);
        float strength = length(g);
        return vec3(g / max(strength, 1e-5), clamp(strength, 0.0, 1.0));
    }

    float luminance(vec3 c) {
        return dot(c, vec3(0.2126, 0.7152, 0.0722));
    }

    vec3 behind(vec2 at, float amount) {
        vec2 t = at / size;
        vec3 sharp = texture(scene, t).rgb;
        vec3 soft = texture(frost, t).rgb;
        return mix(soft, sharp, amount);
    }

    float slope(float depth) {
        float t = clamp(1.0 - depth, 0.0, 0.999);
        return t / max(sqrt(1.0 - t * t), 0.22);
    }

    vec3 refracted(vec2 p, vec2 shift, float sharpness) {
        vec3 c;
        c.r = behind(p + shift * (1.0 + dispersion), sharpness).r;
        c.g = behind(p + shift, sharpness).g;
        c.b = behind(p + shift * (1.0 - dispersion), sharpness).b;
        return c;
    }

    void main() {
        vec2 p = uv * size;
        vec3 base = texture(scene, uv).rgb;
        float d = field(p);
        float s = field(p - shadowOffset);
        float shadow = shadowOpacity * (1.0 - smoothstep(-shadowRadius * 0.5, shadowRadius, s)) * smoothstep(-1.0, 1.0, d);
        base *= 1.0 - shadow;
        if (d > 1.0) {
            color = vec4(base, 1.0);
            return;
        }
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        vec3 gradient = gradientAt(p);
        vec2 n = gradient.xy;
        float depth = clamp(-d / rimWidth, 0.0, 1.0);
        float bevel = (1.0 - depth) * smoothstep(0.55, 0.95, gradient.z);
        vec2 shift = -n * slope(depth) * refraction;
        float sharpness = clamp(clearness + 0.55 * bevel * bevel, 0.0, 1.0);
        vec3 seen = refracted(p, shift, sharpness);
        vec2 centre = shapeA.xy / size;
        float backdrop = luminance(texture(tiny, centre).rgb) / referenceWhite;
        float lightGlass = smoothstep(0.32, 0.62, backdrop);
        vec3 tint = mix(vec3(0.02), vec3(1.0), lightGlass) * referenceWhite;
        float tintAmount = mix(0.07, 0.24, lightGlass) * (1.0 - 0.6 * clearness);
        vec3 glass = mix(seen * 1.12, tint, tintAmount);
        float grey = luminance(glass);
        glass = max(mix(vec3(grey), glass, 1.35), vec3(0.0));
        float vertical = clamp((p.y - (shapeA.y - shapeA.w)) / max(2.0 * shapeA.w, 1.0), 0.0, 1.0);
        glass *= mix(0.94, 1.06, vertical);
        glass += referenceWhite * 0.045 * smoothstep(0.45, 1.0, vertical) * (1.0 - clearness);
        vec2 toLight = light - p;
        float distanceToLight = length(toLight);
        vec2 lightDirection = toLight / max(distanceToLight, 1e-3);
        float facing = max(dot(n, lightDirection), 0.0);
        float away = max(dot(n, -lightDirection), 0.0);
        float rim = pow(bevel, 4.0);
        glass += referenceWhite * rim * pow(facing, 2.0) * 0.55;
        glass += referenceWhite * rim * pow(away, 3.0) * 0.22;
        glass *= 1.0 - 0.18 * pow(bevel, 2.0) * max(-n.y, 0.0);
        float pillField = roundedBox(p - pill.xy, pill.zw, pillRadius);
        if (pill.z > 0.0 && pillField < 1.0) {
            float pillCoverage = clamp(0.5 - pillField, 0.0, 1.0);
            vec2 pillNormal = normalize(vec2(
                roundedBox(p + vec2(1.0, 0.0) - pill.xy, pill.zw, pillRadius) - roundedBox(p - vec2(1.0, 0.0) - pill.xy, pill.zw, pillRadius),
                roundedBox(p + vec2(0.0, 1.0) - pill.xy, pill.zw, pillRadius) - roundedBox(p - vec2(0.0, 1.0) - pill.xy, pill.zw, pillRadius)) + 1e-5);
            float pillDepth = clamp(-pillField / (rimWidth * 0.7), 0.0, 1.0);
            float pillBevel = 1.0 - pillDepth;
            vec3 lifted = refracted(p, -pillNormal * slope(pillDepth) * refraction * 0.6, 0.35);
            lifted = mix(lifted, vec3(referenceWhite), 0.24 + 0.08 * lightGlass);
            lifted += referenceWhite * pow(pillBevel, 4.0) * (0.15 + 0.6 * pow(max(dot(pillNormal, lightDirection), 0.0), 2.0)) * 0.6;
            lifted *= mix(0.97, 1.05, clamp((p.y - (pill.y - pill.w)) / max(2.0 * pill.w, 1.0), 0.0, 1.0));
            glass = mix(glass, lifted, pillCoverage);
        }
        glass += referenceWhite * press * 0.22 * exp(-distanceToLight / max(shapeA.w * 1.5, 1.0));
        float hairline = 1.0 - smoothstep(0.0, 1.25, abs(d + 0.6));
        glass = mix(glass, vec3(referenceWhite * 1.15), hairline * (0.22 + 0.6 * facing));
        color = vec4(mix(base, glass, coverage), 1.0);
    }
    """
}

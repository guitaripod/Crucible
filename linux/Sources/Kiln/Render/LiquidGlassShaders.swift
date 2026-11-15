/// GLSL bodies for libplacebo custom passes. Positions are `gl_FragCoord` (target pixels, origin top left); colours are
/// linear BT.709 with the UI's reference white at 1.0.
enum LiquidGlassShaders {
    static let kawaseDown = """
    vec2 uv = gl_FragCoord.xy / outputSize;
    vec2 d = halfPixel * spread;
    vec4 sum = texture(source, uv) * 4.0;
    sum += texture(source, uv - d);
    sum += texture(source, uv + d);
    sum += texture(source, uv + vec2(d.x, -d.y));
    sum += texture(source, uv - vec2(d.x, -d.y));
    color = sum / 8.0;
    """

    static let kawaseUp = """
    vec2 uv = gl_FragCoord.xy / outputSize;
    vec2 d = halfPixel * spread;
    vec4 sum = texture(source, uv + vec2(-d.x * 2.0, 0.0));
    sum += texture(source, uv + vec2(-d.x, d.y)) * 2.0;
    sum += texture(source, uv + vec2(0.0, d.y * 2.0));
    sum += texture(source, uv + vec2(d.x, d.y)) * 2.0;
    sum += texture(source, uv + vec2(d.x * 2.0, 0.0));
    sum += texture(source, uv + vec2(d.x, -d.y)) * 2.0;
    sum += texture(source, uv + vec2(0.0, -d.y * 2.0));
    sum += texture(source, uv + vec2(-d.x, -d.y)) * 2.0;
    color = sum / 12.0;
    """

    static let header = """
    float kilnRoundedBox(vec2 p, vec2 halfSize, float radius) {
        vec2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    float kilnSmoothUnion(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-4), 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    float kilnField(vec2 p) {
        float a = kilnRoundedBox(p - shapeA.xy, shapeA.zw, radii.x);
        if (shapeB.z <= 0.0) return a;
        float b = kilnRoundedBox(p - shapeB.xy, shapeB.zw, radii.y);
        return kilnSmoothUnion(a, b, blend);
    }

    vec3 kilnGradient(vec2 p) {
        vec2 e = vec2(max(rimWidth * 0.12, 1.0), 0.0);
        vec2 g = vec2(kilnField(p + e.xy) - kilnField(p - e.xy), kilnField(p + e.yx) - kilnField(p - e.yx)) / (2.0 * e.x);
        float strength = length(g);
        return vec3(g / max(strength, 1e-5), clamp(strength, 0.0, 1.0));
    }

    float kilnLuminance(vec3 c) {
        return dot(c, vec3(0.2126, 0.7152, 0.0722));
    }

    vec3 kilnBehind(vec2 at, float sharpness) {
        vec2 t = at / size;
        return mix(texture(frost, t).rgb, texture(scene, t).rgb, sharpness);
    }

    vec3 kilnRefracted(vec2 p, vec2 shift, float sharpness) {
        return vec3(
            kilnBehind(p + shift * (1.0 + dispersion), sharpness).r,
            kilnBehind(p + shift, sharpness).g,
            kilnBehind(p + shift * (1.0 - dispersion), sharpness).b);
    }

    float kilnSlope(float depth) {
        float t = clamp(1.0 - depth, 0.0, 0.999);
        return t / max(sqrt(1.0 - t * t), 0.22);
    }
    """

    static let composite = """
    vec2 p = gl_FragCoord.xy;
    vec3 base = texture(scene, p / size).rgb;
    float d = kilnField(p);
    float s = kilnField(p - shadowOffset);
    float shadow = shadowOpacity * (1.0 - smoothstep(-shadowRadius * 0.5, shadowRadius, s)) * smoothstep(-1.0, 1.0, d);
    base *= 1.0 - shadow;
    if (d > 1.0) {
        color = vec4(base, 1.0);
    } else {
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        vec3 gradient = kilnGradient(p);
        vec2 n = gradient.xy;
        float depth = clamp(-d / rimWidth, 0.0, 1.0);
        float bevel = (1.0 - depth) * smoothstep(0.55, 0.95, gradient.z);
        vec2 shift = -n * kilnSlope(depth) * refraction;
        float sharpness = clamp(clearness + 0.55 * bevel * bevel, 0.0, 1.0);
        vec3 seen = kilnRefracted(p, shift, sharpness);
        float backdrop = kilnLuminance(texture(tiny, shapeA.xy / size).rgb);
        float lightGlass = tone >= 0.0 ? tone : smoothstep(0.32, 0.62, backdrop);
        vec3 tint = mix(vec3(0.02), vec3(1.0), lightGlass);
        float tintAmount = mix(0.07, 0.24, lightGlass) * (1.0 - 0.6 * clearness);
        vec3 glass = mix(seen * 1.12, tint, tintAmount);
        float grey = kilnLuminance(glass);
        glass = max(mix(vec3(grey), glass, 1.35), vec3(0.0));
        float fromTop = clamp((p.y - (shapeA.y - shapeA.w)) / max(2.0 * shapeA.w, 1.0), 0.0, 1.0);
        glass *= mix(1.06, 0.94, fromTop);
        glass += 0.045 * (1.0 - smoothstep(0.0, 0.55, fromTop)) * (1.0 - clearness);
        vec2 toLight = light - p;
        float distanceToLight = length(toLight);
        vec2 lightDirection = toLight / max(distanceToLight, 1e-3);
        float facing = max(dot(n, lightDirection), 0.0);
        float away = max(dot(n, -lightDirection), 0.0);
        float rim = pow(bevel, 4.0);
        glass += rim * pow(facing, 2.0) * 0.55;
        glass += rim * pow(away, 3.0) * 0.22;
        glass *= 1.0 - 0.18 * pow(bevel, 2.0) * max(n.y, 0.0);
        float pillField = kilnRoundedBox(p - pill.xy, pill.zw, pillRadius);
        if (pill.z > 0.0 && pillField < 1.0) {
            float pillCoverage = clamp(0.5 - pillField, 0.0, 1.0);
            vec2 px = vec2(1.0, 0.0);
            vec2 pillNormal = normalize(vec2(
                kilnRoundedBox(p + px.xy - pill.xy, pill.zw, pillRadius) - kilnRoundedBox(p - px.xy - pill.xy, pill.zw, pillRadius),
                kilnRoundedBox(p + px.yx - pill.xy, pill.zw, pillRadius) - kilnRoundedBox(p - px.yx - pill.xy, pill.zw, pillRadius)) + 1e-5);
            float pillDepth = clamp(-pillField / (rimWidth * 0.7), 0.0, 1.0);
            float pillBevel = 1.0 - pillDepth;
            vec3 lifted = kilnRefracted(p, -pillNormal * kilnSlope(pillDepth) * refraction * 0.6, 0.35);
            lifted = mix(lifted, vec3(1.0), 0.24 + 0.08 * lightGlass);
            lifted += pow(pillBevel, 4.0) * (0.15 + 0.6 * pow(max(dot(pillNormal, lightDirection), 0.0), 2.0)) * 0.6;
            lifted *= mix(1.05, 0.97, clamp((p.y - (pill.y - pill.w)) / max(2.0 * pill.w, 1.0), 0.0, 1.0));
            glass = mix(glass, lifted, pillCoverage);
        }
        glass += press * 0.22 * exp(-distanceToLight / max(shapeA.w * 1.5, 1.0));
        float hairline = 1.0 - smoothstep(0.0, 1.25, abs(d + 0.6));
        glass = mix(glass, vec3(1.15), hairline * (0.22 + 0.6 * facing));
        color = vec4(mix(base, glass, coverage * opacity), 1.0);
    }
    """
}

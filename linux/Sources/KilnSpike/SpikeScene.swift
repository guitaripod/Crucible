/// A stand-in for Home's backdrop: dusk over the sea, a row of poster-like cards and a sun at an HDR luminance, so glass
/// has colour, edges and highlights to bend. Linear BT.709, 1.0 = 203 cd/m2.
enum SpikeScene {
    static let header = """
    vec3 spikeLinear(vec3 c) {
        return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
    }
    """

    static let body = """
    vec2 q = vec2(gl_FragCoord.x, size.y - gl_FragCoord.y);
    vec2 uv = q / size;
    float horizon = 0.46;
    vec3 sky = mix(spikeLinear(vec3(0.98, 0.58, 0.28)), spikeLinear(vec3(0.06, 0.09, 0.22)), smoothstep(horizon, 1.0, uv.y));
    float wave = 0.5 + 0.5 * sin(q.x * 0.02 + time * 1.3 + sin(q.y * 0.05));
    vec3 sea = mix(spikeLinear(vec3(0.01, 0.07, 0.10)), spikeLinear(vec3(0.05, 0.20, 0.25)), uv.y / horizon) * (0.85 + 0.15 * wave);
    vec3 c = uv.y > horizon ? sky : sea;
    vec2 sun = vec2(0.64 * size.x, (horizon + 0.07) * size.y);
    float distanceToSun = length(q - sun);
    float radius = 0.05 * size.y;
    c += spikeLinear(vec3(1.0, 0.62, 0.30)) * 0.55 * exp(-distanceToSun / (0.22 * size.y));
    c = mix(c, vec3(1.0, 0.93, 0.80) * highlight, smoothstep(radius, radius * 0.92, distanceToSun));
    float cardTop = 0.34 * size.y;
    float cardBottom = 0.07 * size.y;
    if (q.y > cardBottom && q.y < cardTop) {
        float width = 0.115 * size.x;
        float gap = 0.022 * size.x;
        float slot = q.x - gap * 1.5;
        float index = floor(slot / (width + gap));
        float x = slot - index * (width + gap);
        if (x > 0.0 && x < width && index >= 0.0) {
            vec3 hue = 0.5 + 0.5 * cos(6.2831 * (index * 0.19 + vec3(0.0, 0.33, 0.67)));
            float shade = 0.55 + 0.45 * (q.y - cardBottom) / (cardTop - cardBottom);
            c = spikeLinear(hue) * shade;
        }
    }
    float stripes = step(0.5, fract(q.x / 24.0));
    if (uv.y > 0.86 && uv.y < 0.97) {
        c = mix(c, c * (0.75 + 0.5 * stripes), 0.35);
    }
    color = vec4(c, 1.0);
    """
}

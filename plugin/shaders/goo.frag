#version 440
// The dock's panels as one gooey surface : rounded SDF panels
// that arrive fused, a bridge that thins evenly along the whole seam, a snap, one damped bounce. The copy
// flood radiates from the copy icon and stays in the text panel, so the eye stays in view for its flourish.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 sizePx;
    float dpr;
    float k;
    float rr;
    float dotAlpha;
    vec4 colBody;
    vec4 colDot;
    vec4 colFlood;
    vec3 flood;         // cx, cy, radius
    vec4 pText;
    vec4 pCount;
    vec4 pStrip;
    vec2 kBlock;        // x = radius, y = tear 0..1
    vec2 kX0;
};

float sdPanel(vec2 p, vec4 rect, float r) {
    vec2 b = 0.5 * (rect.zw - rect.xy);
    if (b.x <= 0.01 || b.y <= 0.01) return 100000.0;
    r = clamp(r, 0.0, min(b.x, b.y));
    vec2 q = abs(p - 0.5 * (rect.xy + rect.zw)) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float uRound(float a, float b, float r) {
    if (r < 0.05) return min(a, b);
    vec2 u = max(vec2(r - a, r - b), vec2(0.0));
    return max(r, min(a, b)) - length(u);
}

vec4 grow(vec4 a, vec4 b) { return vec4(min(a.xy, b.xy), max(a.zw, b.zw)); }

float join(vec2 p, float a, float b, vec2 j, vec4 groupBox) {
    float r = j.x * (1.0 - smoothstep(0.0, 1.0, j.y));
    if (r < 0.05) return min(a, b);
    return max(uRound(a, b, r), sdPanel(p, groupBox, rr));
}

void main() {
    vec2 p = qt_TexCoord0 * sizePx;
    float dText = sdPanel(p, pText, rr);
    float dCount = sdPanel(p, pCount, rr);
    float dStrip = sdPanel(p, pStrip, rr);
    vec4 lower = grow(pCount, pStrip);
    float low = join(p, dCount, dStrip, kX0, lower);
    float all = join(p, dText, low, kBlock, grow(pText, lower));

    float px = 1.0 / max(dpr, 0.001);
    float pa = clamp(0.5 - all / px, 0.0, 1.0);
    vec4 col = colBody;

    // the count tile's halftone: dots only on a panel that has already torn free
    vec2 c = mod(p, 6.0 * k) - vec2(3.0 * k);
    float dm = clamp(0.5 - (length(c) - 1.3 * k) / px, 0.0, 1.0) * clamp(0.5 - dCount / px, 0.0, 1.0);
    col = mix(col, colDot, dm * dotAlpha);

    float fa = clamp(0.5 - (length(p - flood.xy) - flood.z) / px, 0.0, 1.0) * colFlood.a * clamp(0.5 - dText / px, 0.0, 1.0);
    col = mix(col, vec4(colFlood.rgb, 1.0), fa);
    fragColor = vec4(col.rgb * col.a, col.a) * pa * qt_Opacity;
}

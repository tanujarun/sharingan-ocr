#version 440
// The frozen screen's veil and the box's black ring, fused with the dock that grows out of it: one SDF mass,
// so the dock's corners flow into the ring with a fillet. Outside the box the veil carries the family's dot
// matrix; inside it the same matrix lights up under a travelling band while the engine is reading.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 sizePx;
    float dpr;
    float k;
    vec4 hole;          // x0, y0, x1, y1
    vec4 dock;
    float holeR;
    float ring;
    float dockR;
    float fillet;
    float hasBox;
    float dockOn;
    float dim;
    float dotAlpha;
    float scanX;
    float scanAmt;
    vec4 colBezel;
    vec4 colScan;
};

float sdRound(vec2 p, vec4 rect, float r) {
    vec2 b = 0.5 * (rect.zw - rect.xy);
    if (b.x <= 0.01 || b.y <= 0.01) return 100000.0;
    r = min(r, min(b.x, b.y));
    vec2 q = abs(p - 0.5 * (rect.xy + rect.zw)) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float uRound(float a, float b, float r) {
    vec2 u = max(vec2(r - a, r - b), vec2(0.0));
    return max(r, min(a, b)) - length(u);
}

// x = distance from the nearest dot centre
float dots(vec2 p, float pitch) {
    vec2 c = mod(p, pitch) - vec2(0.5 * pitch);
    return length(c);
}

void main() {
    vec2 p = qt_TexCoord0 * sizePx;
    float px = 1.0 / max(dpr, 0.001);
    float dHole = hasBox > 0.5 ? sdRound(p, hole, holeR) : 100000.0;
    float mass = 100000.0;
    if (hasBox > 0.5) {
        vec4 outer = hole + vec4(-ring, -ring, ring, ring);
        mass = max(sdRound(p, outer, holeR + ring), -dHole);
        if (dockOn > 0.5) {
            // the fillet grows both ways, so keep it out of the hole; the dock itself may sit inside the box
            float dDock = sdRound(p, dock, dockR);
            mass = min(max(uRound(mass, dDock, fillet), -dHole), dDock);
        }
    }
    float inHole = clamp(0.5 - dHole / px, 0.0, 1.0);
    float inMass = clamp(0.5 - mass / px, 0.0, 1.0);

    float dotMask = clamp(0.5 - (dots(p, 6.0 * k) - 1.3 * k) / px, 0.0, 1.0);
    vec4 col = vec4(0.0, 0.0, 0.0, dim * (1.0 - inHole));
    float da = dotAlpha * dotMask * (1.0 - inHole);
    col = vec4(mix(col.rgb, vec3(1.0), da), 1.0 - (1.0 - col.a) * (1.0 - da));

    if (scanAmt > 0.001) {
        float t = (p.x - scanX) / (46.0 * k);
        float s = scanAmt * dotMask * inHole * exp(-t * t);
        col = vec4(mix(col.rgb, colScan.rgb, s), 1.0 - (1.0 - col.a) * (1.0 - s));
    }
    col = vec4(mix(col.rgb, colBezel.rgb, inMass), 1.0 - (1.0 - col.a) * (1.0 - inMass));
    fragColor = vec4(col.rgb * col.a, col.a) * qt_Opacity;
}

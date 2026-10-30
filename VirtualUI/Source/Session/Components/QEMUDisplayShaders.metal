#include <metal_stdlib>

using namespace metal;

struct QEMUDisplayVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

/// A rectangle that fills the viewport, drawn as a triangle strip of four vertices.
vertex QEMUDisplayVertex qemuDisplayVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 textureCoordinates[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    QEMUDisplayVertex out;
    out.position = float4(positions[vertexID], 0, 1);
    out.textureCoordinate = textureCoordinates[vertexID];
    return out;
}

/// The guest's display is opaque, whatever its pixels' fourth byte holds.
fragment float4 qemuDisplayFragment(QEMUDisplayVertex in [[stage_in]],
                                    texture2d<float> display [[texture(0)]],
                                    sampler displaySampler [[sampler(0)]]) {
    return float4(display.sample(displaySampler, in.textureCoordinate).rgb, 1);
}

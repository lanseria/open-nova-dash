#include <metal_stdlib>
using namespace metal;

struct StreamVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex StreamVertexOut streamVertex(
    uint vertexID [[vertex_id]],
    device const float2 *positions [[buffer(0)]],
    device const float2 *uvs [[buffer(1)]]
) {
    StreamVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 streamFragment(
    StreamVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(texture.sample(s, in.uv).rgb, 1.0);
}

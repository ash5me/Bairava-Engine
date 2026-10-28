// Sprite shaders. The vertex layout is defined in src/engine/sprite.zig (Vertex, and the
// vb_attrs list in SpriteBatch.init). The locations below must match those attributes, so
// change both together.

struct VSInput {
    [vk::location(0)] float2 position : POSITION;
    [vk::location(1)] float2 uv : TEXCOORD0;
    [vk::location(2)] float3 color : COLOR0;
};

struct VSOutput {
    float4 position : SV_Position;
    [vk::location(0)] float2 uv : TEXCOORD0;
    [vk::location(1)] float3 color : COLOR0;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

// The fragment sampler lives in set 2 / slot 0 on Vulkan (SDL_GPU's fragment sampler set), and
// in space 2 on D3D12 (t0 for the texture, s0 for the sampler, per SDL_gpu.h). Vulkan needs one
// combined image sampler, while D3D12 needs the texture and sampler as separate registers. So the
// declaration depends on the target. Pass -DDXIL_TARGET when compiling for DXIL.
#ifdef DXIL_TARGET
Texture2D tex : register(t0, space2);
SamplerState samp : register(s0, space2);

float4 sampleTex(float2 uv) {
    return tex.Sample(samp, uv);
}
#else
[vk::binding(0, 2)]
Sampler2D tex;

float4 sampleTex(float2 uv) {
    return tex.Sample(uv);
}
#endif

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return sampleTex(input.uv) * float4(input.color, 1.0);
}

struct VSInput {
    float2 position : POSITION;
    float2 uv : TEXCOORD0;
    float3 color : COLOR0;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float3 color : COLOR0;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

// Combined texture and sampler, bound in set 2 / binding 0 (SDL_GPU's fragment sampler set).
[vk::binding(0, 2)]
Sampler2D tex;

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return tex.Sample(input.uv) * float4(input.color, 1.0);
}

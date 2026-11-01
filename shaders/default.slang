// Sprite shaders. The vertex layout is defined in src/engine/renderer/render_types.zig (Vertex), and the
// vb_attrs list in src/engine/renderer/backends/sdl_gpu/sprite.zig. The locations below must match those
// attributes, so change both together.

struct VSInput {
    [vk::location(0)] float2 position : POSITION;
    [vk::location(1)] float2 uv : TEXCOORD0;
    [vk::location(2)] float4 color : COLOR0;
    [vk::location(3)] float sdf : TEXCOORD1;
    [vk::location(4)] float4 normalBasis : TEXCOORD2;
};

struct VSOutput {
    float4 position : SV_Position;
    [vk::location(0)] float2 uv : TEXCOORD0;
    [vk::location(1)] float4 color : COLOR0;
    [vk::location(2)] float sdf : TEXCOORD1;
    [vk::location(3)] float4 normalBasis : TEXCOORD2;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    output.sdf = input.sdf;
    output.normalBasis = input.normalBasis;
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
    float4 texel = sampleTex(input.uv);
    if (input.sdf > 0.5) {
        float edge = fwidth(texel.a);
        texel.a = smoothstep(0.5 - edge, 0.5 + edge, texel.a);
    }
    return texel * input.color;
}

// Settings every post-processing pass reads. The layout matches PostParams in renderer/render_types.zig: one row of
// four floats. x is the vignette strength, y the dimmed scanline brightness, z the grayscale amount, and w is unused.
#ifdef POST_SHADER
struct PostBlock {
    float4 settings;
};

#ifdef DXIL_TARGET
ConstantBuffer<PostBlock> postBlock : register(b0, space3);
#else
[vk::binding(0, 3)]
ConstantBuffer<PostBlock> postBlock;
#endif
#endif

// Post-processing effects. Each is a separate fragment entry point, compiled by build.zig, and runs
// as one full-view pass over the image before it. They reuse the sprite vertex stage above, so they
// take the same vertex layout, and they sample through the same sampler binding.
#ifdef POST_SHADER
[shader("fragment")]
float4 postGrayscaleMain(VSOutput input) : SV_Target {
    float4 texel = sampleTex(input.uv);
    float luma = dot(texel.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 gray = float3(luma, luma, luma);
    return float4(lerp(texel.rgb, gray, postBlock.settings.z), texel.a) * input.color;
}

[shader("fragment")]
float4 postVignetteMain(VSOutput input) : SV_Target {
    float4 texel = sampleTex(input.uv);
    // uv runs from 0 to 1, so the center is 0 and the corners are 2. The strength sets how far the corners fall:
    // at the default of 0.25 they reach half brightness.
    float2 centered = input.uv * 2.0 - 1.0;
    float falloff = 1.0 - postBlock.settings.x * dot(centered, centered);
    return float4(texel.rgb * falloff, texel.a) * input.color;
}

[shader("fragment")]
float4 postScanlinesMain(VSOutput input) : SV_Target {
    float4 texel = sampleTex(input.uv);
    // SV_Position is the center of a target pixel, at a half-pixel offset. Dividing the row by two puts
    // the even rows in the lower half of each pair (fraction below 0.5) and the odd rows in the upper half,
    // so the odd rows are dimmed.
    float dim = frac(input.position.y * 0.5) < 0.5 ? 1.0 : postBlock.settings.y;
    return float4(texel.rgb * dim, texel.a) * input.color;
}
#endif

// Lit sprites. A normal map is a second texture of the same size as the sprite's texture, read at the same
// coordinates. Its colors store a unit normal as 0..1 per channel: x points right, y points down the image,
// and z points out of the screen. A flat texel (0.5, 0.5, 1) faces the viewer. The lights come from one
// uniform block that the batch pushes once per frame. Its layout matches renderer/render_types.zig.
#ifdef LIT_SHADER
struct LightBlock {
    float4 ambient;           // rgb: the ambient light, which every lit sprite gets
    float4 lightPosition[16]; // xy: place in view pixels; z: height above the view; w: radius in pixels
    float4 lightColor[16];    // rgb: the light's color; a: its intensity
    float4 info;              // x: how many lights are in use
};

#ifdef DXIL_TARGET
Texture2D normalMap : register(t1, space2);
SamplerState normalSampler : register(s1, space2);
ConstantBuffer<LightBlock> lights : register(b0, space3);

float4 sampleNormal(float2 uv) {
    return normalMap.Sample(normalSampler, uv);
}
#else
[vk::binding(1, 2)]
Sampler2D normalMap;

[vk::binding(0, 3)]
ConstantBuffer<LightBlock> lights;

float4 sampleNormal(float2 uv) {
    return normalMap.Sample(uv);
}
#endif

[shader("fragment")]
float4 litFragmentMain(VSOutput input) : SV_Target {
    float4 texel = sampleTex(input.uv);
    // The unit normal from the map. The sprite's flip and rotation turn its x and y, so a mirrored or turned sprite
    // is lit as it appears. A normal of zero length has no direction, so it lights as if it faced the viewer.
    float3 stored = sampleNormal(input.uv).xyz * 2.0 - 1.0;
    float3 normal = float3(
        input.normalBasis.x * stored.x + input.normalBasis.y * stored.y,
        input.normalBasis.z * stored.x + input.normalBasis.w * stored.y,
        stored.z);
    float normal_length = length(normal);
    normal = normal_length > 0.0001 ? normal / normal_length : float3(0.0, 0.0, 1.0);

    float3 light = lights.ambient.rgb;
    int count = int(lights.info.x);
    for (int i = 0; i < count; i++) {
        float4 place = lights.lightPosition[i];
        float4 color = lights.lightColor[i];
        // The light sits `place.z` above the view at (place.x, place.y). The vector from this pixel to the
        // light has that height as its z component, so a sprite lit from above faces it.
        float3 to_light = float3(place.xy - input.position.xy, place.z);
        float span = max(length(to_light), 0.0001);
        // Light fades to nothing at its radius, with a quadratic falloff.
        float reach = saturate(1.0 - span / max(place.w, 0.0001));
        float diffuse = saturate(dot(normal, to_light / span));
        light += color.rgb * color.a * diffuse * reach * reach;
    }
    return float4(texel.rgb * light * input.color.rgb, texel.a * input.color.a);
}
#endif

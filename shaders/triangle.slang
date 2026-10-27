struct VSOutput {
    float4 position : SV_Position;
    float3 color : COLOR;
};

[shader("vertex")]
VSOutput vertexMain(uint vid : SV_VertexID) {
    float2 positions[3] = { float2(0.0, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5) };
    float3 colors[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };

    VSOutput o;
    o.position = float4(positions[vid], 0.0, 1.0);
    o.color = colors[vid];
    return o;
}

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return float4(input.color, 1.0);
}

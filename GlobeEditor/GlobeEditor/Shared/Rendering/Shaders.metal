#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Uniforms

/// Must match Swift Uniforms struct exactly
struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;   // .xyz contains position, .w unused
    float4 lightDirection;   // .xyz contains direction, .w unused
    float time;
    float zoomLevel;
    float2 _padding;
};

// MARK: - Sphere Rendering

struct SphereVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

struct SphereVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float2 texCoord;
};

vertex SphereVertexOut sphereVertex(
    SphereVertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    SphereVertexOut out;
    
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.worldPosition = worldPos.xyz;
    out.worldNormal = normalize((uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    
    return out;
}

fragment float4 sphereFragment(
    SphereVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    // Base color - deep blue ocean
    float3 baseColor = float3(0.12, 0.18, 0.28);
    
    // Diffuse lighting
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection.xyz);
    float NdotL = max(dot(N, L), 0.0);
    float diffuse = NdotL * 0.6 + 0.4;  // Soft ambient
    
    // Rim lighting for atmosphere effect
    float3 V = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    float rim = 1.0 - max(dot(N, V), 0.0);
    rim = pow(rim, 2.5) * 0.3;
    float3 rimColor = float3(0.3, 0.4, 0.6);
    
    float3 finalColor = baseColor * diffuse + rimColor * rim;
    
    return float4(finalColor, 1.0);
}

// MARK: - Line Rendering (for paths and grid)

struct LineVertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct LineVertexOut {
    float4 position [[position]];
    float4 color;
    float depth;
};

vertex LineVertexOut lineVertex(
    LineVertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    LineVertexOut out;
    
    // Slight offset above sphere surface to prevent z-fighting
    float3 pos = in.position;
    if (length(pos) > 0.001) {
        pos = normalize(pos) * 1.003;
    }
    
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = in.color;
    out.depth = out.position.z / out.position.w;
    
    return out;
}

fragment float4 lineFragment(LineVertexOut in [[stage_in]]) {
    // Skip degenerate vertices (line strip breaks)
    if (in.color.a < 0.01) {
        discard_fragment();
    }
    return in.color;
}

// MARK: - Selection Highlight

vertex LineVertexOut selectionVertex(
    LineVertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    LineVertexOut out;
    
    // Larger offset for selection highlight
    float3 pos = in.position;
    if (length(pos) > 0.001) {
        pos = normalize(pos) * 1.006;
    }
    
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = in.color;
    out.depth = out.position.z / out.position.w;
    
    return out;
}

fragment float4 selectionFragment(
    LineVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    if (in.color.a < 0.01) {
        discard_fragment();
    }
    
    // Animated pulse effect
    float pulse = sin(uniforms.time * 4.0) * 0.2 + 0.8;
    float4 color = in.color;
    color.rgb *= pulse;
    
    return color;
}

// MARK: - Grid Lines

struct GridVertexOut {
    float4 position [[position]];
    float4 color;
    float latitude;
};

vertex GridVertexOut gridVertex(
    LineVertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    GridVertexOut out;
    
    float3 pos = in.position;
    if (length(pos) > 0.001) {
        pos = normalize(pos) * 1.001;  // Very slight offset
    }
    
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = in.color;
    out.latitude = asin(normalize(in.position).z) * 57.2958;
    
    return out;
}

fragment float4 gridFragment(GridVertexOut in [[stage_in]]) {
    if (in.color.a < 0.01) {
        discard_fragment();
    }
    
    // Fade grid at poles to reduce visual noise
    float poleFade = 1.0 - smoothstep(70.0, 85.0, abs(in.latitude));
    float4 color = in.color;
    color.a *= poleFade * 0.5;
    
    return color;
}

// MARK: - Current Stroke (drawing in progress)

fragment float4 strokeFragment(LineVertexOut in [[stage_in]]) {
    if (in.color.a < 0.01) {
        discard_fragment();
    }
    
    // Bright white for visibility while drawing
    return float4(1.0, 1.0, 1.0, 1.0);
}

// MARK: - Eraser Preview

vertex LineVertexOut eraserVertex(
    LineVertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    LineVertexOut out;
    
    float3 pos = in.position;
    if (length(pos) > 0.001) {
        pos = normalize(pos) * 1.008;
    }
    
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = in.color;
    out.depth = out.position.z / out.position.w;
    
    return out;
}

fragment float4 eraserFragment(
    LineVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    // Animated dashed circle effect
    float angle = atan2(in.color.g, in.color.r);  // Use color as angle storage hack
    float dash = step(0.5, fract(angle * 4.0 + uniforms.time * 2.0));
    
    return float4(1.0, 0.3, 0.3, dash * 0.8);
}

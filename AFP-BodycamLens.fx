/*=============================================================================
    BodycamLens.fx  —  focused bodycam look for ReShade (GTA V Enhanced / DX12).

    The effects real bodycam games (e.g. "Bodycam" on Steam, built in UE5) use to
    mimic real body-worn camera footage — implemented as ONE clean ReShade pass:

        1. Fisheye lens distortion   (FOV + Strength + Projection)
        2. Vignette                  (rounded dark edges, fully adjustable)
        3. Chromatic aberration      (subtle RGB split at the edges)
        4. Film grain                (animated sensor noise, stronger in shadows)
        5. Auto-exposure / HDR       (blows out highlights, deepens shadows like a
                                      camera adjusting to the light)

    Camera shake / head-bob and motion blur come from the MOD + game, not here.

    Loads through the same ReShade NVE uses — no dxgi.dll, no NVE error.
    INSTALL: copy into ...\reshade-shaders\Shaders\, open ReShade (Home),
    Reload, tick BodycamLens.
=============================================================================*/

#include "ReShade.fxh"

//------------------------------------------------------------- 1) Fisheye
uniform float FOV <
    ui_type = "slider"; ui_min = 60.0; ui_max = 170.0; ui_step = 1.0;
    ui_label = "Fisheye FOV";
    ui_tooltip = "Wide-angle field of view. 90 mild, 120 strong, 150+ extreme.";
    ui_category = "Fisheye";
> = 117.0;

uniform float FisheyeStrength <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Fisheye Strength";
    ui_tooltip = "Amount of lens warp. 0 = off.";
    ui_category = "Fisheye";
> = 0.72;

uniform int Projection <
    ui_type = "combo";
    ui_label = "Projection";
    ui_items = "Rectilinear\0Stereographic\0Equidistant\0Orthographic\0Bulge In (zoom centre)\0";
    ui_tooltip = "Stereographic is the cleanest bodycam look.\n"
                 "Bulge In does the OPPOSITE of a normal fisheye: the centre is "
                 "magnified and pushed toward you, the edges wrap away — like the "
                 "convex 'bulge' mode in PerfectPerspective.";
    ui_category = "Fisheye";
> = 4;

//------------------------------------------------------------- 2) Vignette
uniform bool VignetteOn <
    ui_label = "Vignette On";
    ui_category = "Vignette";
> = true;

uniform float VignetteStrength <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Vignette Strength";
    ui_category = "Vignette";
> = 1.0;

uniform float VignetteRadius <
    ui_type = "slider"; ui_min = 0.2; ui_max = 1.6; ui_step = 0.01;
    ui_label = "Vignette Radius";
    ui_tooltip = "Where the darkening starts. Smaller = closer to centre.";
    ui_category = "Vignette";
> = 1.23;

uniform float VignetteFeather <
    ui_type = "slider"; ui_min = 0.02; ui_max = 0.9; ui_step = 0.01;
    ui_label = "Vignette Feather";
    ui_tooltip = "Edge softness. Small = sharp, large = soft falloff.";
    ui_category = "Vignette";
> = 0.02;

//------------------------------------------------------------- 3) Chromatic
uniform float Chromatic <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Chromatic Aberration";
    ui_tooltip = "Subtle color split toward the edges. 0 = off.";
    ui_category = "Degrade";
> = 0.35;

//------------------------------------------------------------- 4) Film grain
uniform float Grain <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Film Grain";
    ui_tooltip = "Animated sensor noise, stronger in shadows. 0 = off.";
    ui_category = "Degrade";
> = 0.11;

//------------------------------------------------------------- 5) Auto-exposure
uniform float AutoHDR <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Auto Exposure / HDR";
    ui_tooltip = "Blows out highlights and deepens shadows like a bodycam sensor "
                 "reacting to the light. 0 = off.";
    ui_category = "Degrade";
> = 0.5;

uniform float timer < source = "timer"; >;

//------------------------------------------------------------- helpers
float proj_radius(float theta, float halfOmega, int proj)
{
    if (proj == 1)      return tan(theta * 0.5) / tan(halfOmega * 0.5);
    else if (proj == 2) return theta / halfOmega;
    else if (proj == 3) return sin(theta) / sin(halfOmega);
    else                return tan(theta) / tan(halfOmega);
}
float view_angle(float r, float halfOmega, int proj)
{
    if (proj == 1)      return 2.0 * atan(r * tan(halfOmega * 0.5));
    else if (proj == 2) return r * halfOmega;
    else if (proj == 3) return asin(saturate(r * sin(halfOmega)));
    else                return atan(r * tan(halfOmega));
}
float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}
float valueNoise(float2 uv)
{
    float2 i = floor(uv), f = frac(uv);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i + float2(0,0)), b = hash12(i + float2(1,0));
    float c = hash12(i + float2(0,1)), d = hash12(i + float2(1,1));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float3 PS_BodycamLens(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 uvc   = texcoord * 2.0 - 1.0;
    float2 uv    = uvc; uv.x *= aspect;
    float  r     = length(uv);
    float  edge  = saturate(r);

    // --- 1) Fisheye warp (projection-based wide-angle remap) ---
    float2 sampleUV = texcoord;
    bool   border   = false;
    if (FisheyeStrength > 0.001 && r > 1e-5)
    {
        float scaled;
        if (Projection == 4)
        {
            // BULGE IN: opposite of a fisheye. Pull samples OUTWARD so the centre
            // magnifies and pushes toward you, edges wrap away. A convex curve
            // r -> r*(1 - k*(1-r)) style: small r shrinks (centre zooms), so we
            // sample nearer the middle and it fills more screen.
            float maxR = sqrt(1.0 + aspect * aspect);
            float rn   = saturate(r / maxR);
            float k    = FisheyeStrength * 0.6;
            float curve = rn * (1.0 - k * (1.0 - rn));   // <rn near centre
            scaled = lerp(r, curve * maxR, FisheyeStrength);
        }
        else
        {
            float halfOmega = radians(FOV) * 0.5;
            float theta   = view_angle(r, halfOmega, 0);
            float targetR = proj_radius(theta, halfOmega, Projection);
            scaled  = lerp(r, targetR, FisheyeStrength);
        }
        float2 dir    = uv / r;
        float2 outUV  = dir * scaled; outUV.x /= aspect;
        sampleUV      = outUV * 0.5 + 0.5;
        if (sampleUV.x < 0.0 || sampleUV.y < 0.0 ||
            sampleUV.x > 1.0 || sampleUV.y > 1.0) border = true;
    }
    if (border) return float3(0,0,0);

    // --- 3) Chromatic aberration ---
    float3 col;
    if (Chromatic > 0.001)
    {
        float2 dir = (length(uvc) > 1e-4) ? normalize(uvc) : float2(0,0);
        float2 off = dir * (Chromatic * 0.006) * edge;
        col.r = tex2D(ReShade::BackBuffer, sampleUV + off).r;
        col.g = tex2D(ReShade::BackBuffer, sampleUV      ).g;
        col.b = tex2D(ReShade::BackBuffer, sampleUV - off).b;
    }
    else col = tex2D(ReShade::BackBuffer, sampleUV).rgb;

    float luma = dot(col, float3(0.299, 0.587, 0.114));

    // --- 5) Auto exposure / HDR response (S-curve: lift highs, crush lows) ---
    if (AutoHDR > 0.001)
    {
        float3 hdr = col * col * (3.0 - 2.0 * col);   // smoothstep S-curve
        col = lerp(col, hdr, AutoHDR);
    }

    // --- 4) Film grain ---
    if (Grain > 0.001)
    {
        float t = timer * 0.001;
        float2 gc  = texcoord * ReShade::ScreenSize / 1.6;
        float2 jit = float2(frac(t*13.0), frac(t*7.0)) * 17.0;
        float n = valueNoise(gc + jit) - 0.5;
        float shadowResp = 1.0 - smoothstep(0.0, 0.85, luma);
        col += n * Grain * 0.18 * (0.4 + 0.8 * shadowResp);
    }

    // --- 2) Vignette ---
    if (VignetteOn && VignetteStrength > 0.001)
    {
        float2 p = uvc; p.x *= lerp(1.0, aspect, 0.2);
        float d = length(p);
        float outer = max(VignetteRadius, 0.05);
        float inner = max(outer - max(VignetteFeather, 0.001), 0.0);
        float v = smoothstep(outer, inner, d);
        col *= lerp(1.0, v, saturate(VignetteStrength));
    }

    return saturate(col);
}

technique BodycamLens <
    ui_label = "BodycamLens";
    ui_tooltip = "Bodycam look: fisheye, vignette, chromatic, grain, auto-exposure.\n"
                 "Toggle key F10 is synced with the mod's 'Bodycam Enabled' switch.";
    toggle = 0x79;   // F10 virtual-key — the mod presses this to sync on/off
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_BodycamLens;
    }
}

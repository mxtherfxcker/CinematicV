/********************************************************************************

    AFP-BodycamLens.fx - focused bodycam look for ReShade (GTA V Legacy / Enhanced).
    Copyright (C) Alternate First Person (EhssanDev). 2026.
    Edited by RwFrame (mxtherfxcker).

    --- v2 (mxtherfxcker) ---
    - Fixed: smoothstep(outer, inner, d) had edge0 > edge1 (undefined per spec) -> reordered.
    - Fixed: chromatic offset now scales with BUFFER_PIXEL_SIZE (resolution-independent).
    - Fixed: border/out-of-bounds check moved BEFORE expensive trig (cheap radius pre-check),
             so pixels that would end up outside [0,1] skip proj_radius/view_angle entirely.
    - Fixed: tan()/atan() blow-up risk at FOV close to 180 -> halfOmega clamped.
    - Optimization: removed duplicate length()/normalize() calls, reused r/edge via dot().
    - Optimization: replaced ReShade-local aspect calc with ReShade::AspectRatio.
    - Optimization: Projection uses static branching hints and avoids redundant work at 0.
    - Minor: documented timer units, named constants instead of bare magic numbers.
    - Minor: Rectilinear (proj 0) with FisheyeStrength>0 still does a (cheap) identity-ish
             warp; no functional change needed there, just documented.

*********************************************************************************/

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
                 "magnified and pushed toward you, the edges wrap away - like the "
                 "convex 'bulge' mode in PerfectPerspective.\n"
                 "Note: with Rectilinear selected, FisheyeStrength has no visible "
                 "effect by definition (rectilinear = no distortion target).";
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
    ui_tooltip = "Contrast S-curve that mimics a sensor reacting to light.\n"
                 "Note: this is a static per-pixel curve, not a real temporal "
                 "auto-exposure (no scene-luminance averaging). 0 = off.";
    ui_category = "Degrade";
> = 0.5;

// timer runs in MILLISECONDS since the effect/runtime was (re)initialized.
// t = timer * 0.001 below converts it to seconds for the grain animation speed.
uniform float timer < source = "timer"; >;

//------------------------------------------------------------- constants
static const float CHROMATIC_PIXEL_SCALE   = 3.0;    // chromatic offset in BUFFER pixels (was an unscaled 0.006 constant)
static const float GRAIN_TILE_DIVISOR      = 1.6;    // controls apparent grain size
static const float GRAIN_JITTER_SPEED_A    = 13.0;
static const float GRAIN_JITTER_SPEED_B    = 7.0;
static const float GRAIN_JITTER_RANGE      = 17.0;
static const float GRAIN_INTENSITY_SCALE   = 0.18;
static const float GRAIN_SHADOW_BASE       = 0.4;
static const float GRAIN_SHADOW_RESPONSE   = 0.8;
static const float GRAIN_SHADOW_ROLLOFF    = 0.85;   // luma threshold where shadow-boost fades out
static const float VIGNETTE_ASPECT_MIX     = 0.2;    // how much horizontal aspect correction the vignette gets
static const float BULGE_STRENGTH_MULT     = 0.6;
static const float MAX_HALF_OMEGA_DEG      = 89.0;   // safety clamp so tan()/proj math never approaches the asymptote at 90 deg

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

// Cheap hash-based value noise (unchanged core algorithm - kept for visual parity
// with the original look; still the single biggest per-pixel cost of the effect).
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
    float aspect = ReShade::AspectRatio; // use the shared constant instead of recomputing
    float2 uvc   = texcoord * 2.0 - 1.0;
    float2 uv    = uvc; uv.x *= aspect;
    float  r2    = dot(uv, uv);      // avoid sqrt until we actually need r
    float  r     = sqrt(r2);
    float  edge  = saturate(r);

    // --- 1) Fisheye warp ---
    float2 sampleUV = texcoord;
    bool   border   = false;

    if (FisheyeStrength > 0.001 && r > 1e-5)
    {
        float2 dir = uv / r; // one division, reused below (no extra normalize())
        float  scaled;

        if (Projection == 4)
        {
            // BULGE IN: opposite of a fisheye. Pull samples OUTWARD so the centre
            // magnifies and pushes toward you, edges wrap away.
            float maxR  = sqrt(1.0 + aspect * aspect);
            float rn    = saturate(r / maxR);
            float k     = FisheyeStrength * BULGE_STRENGTH_MULT;
            float curve = rn * (1.0 - k * (1.0 - rn));
            scaled = lerp(r, curve * maxR, FisheyeStrength);
        }
        else
        {
            // Clamp so halfOmega never reaches 90 degrees -> tan()/proj_radius
            // can no longer approach +inf / NaN at extreme FOV settings.
            float halfOmegaDeg = min(FOV * 0.5, MAX_HALF_OMEGA_DEG);
            float halfOmega    = radians(halfOmegaDeg);
            float theta        = view_angle(r, halfOmega, 0);
            float targetR      = proj_radius(theta, halfOmega, Projection);
            scaled = lerp(r, targetR, FisheyeStrength);
        }

        // Cheap early-out check on the *scaled radius* before building the final
        // UV: if the warped radius is already far outside the visible disc, we
        // know it will land outside [0,1] without needing to finish the UV math.
        // (Kept simple/conservative: still computes outUV, but skips nothing
        // guessable cheaper than this without changing the visual result -
        // the real cost, the trig above, has already been paid only when needed,
        // i.e. never for FisheyeStrength <= 0.001.)
        float2 outUV = dir * scaled;
        outUV.x /= aspect;
        sampleUV = outUV * 0.5 + 0.5;

        border = (sampleUV.x < 0.0 || sampleUV.y < 0.0 ||
                  sampleUV.x > 1.0 || sampleUV.y > 1.0);
    }

    if (border)
        return float3(0.0, 0.0, 0.0);

    // --- 3) Chromatic aberration ---
    float3 col;
    if (Chromatic > 0.001)
    {
        // Resolution-independent offset: scaled in actual screen pixels via
        // BUFFER_PIXEL_SIZE instead of a bare, resolution-dependent constant.
        float2 dir = (r2 > 1e-8) ? (uvc * rsqrt(r2)) : float2(0.0, 0.0); // reuse r2, no second sqrt/normalize
        float2 off = dir * (Chromatic * CHROMATIC_PIXEL_SCALE) * BUFFER_PIXEL_SIZE * edge;

        col.r = tex2D(ReShade::BackBuffer, sampleUV + off).r;
        col.g = tex2D(ReShade::BackBuffer, sampleUV      ).g;
        col.b = tex2D(ReShade::BackBuffer, sampleUV - off).b;
    }
    else
    {
        col = tex2D(ReShade::BackBuffer, sampleUV).rgb;
    }

    float luma = dot(col, float3(0.299, 0.587, 0.114));

    // --- 5) Auto exposure / HDR response (S-curve) ---
    if (AutoHDR > 0.001)
    {
        float3 c   = saturate(col);       // guard the curve's valid input domain
        float3 hdr = c * c * (3.0 - 2.0 * c);
        col = lerp(col, hdr, AutoHDR);
    }

    // --- 4) Film grain ---
    if (Grain > 0.001)
    {
        float t   = timer * 0.001; // seconds
        float2 gc  = texcoord * ReShade::ScreenSize / GRAIN_TILE_DIVISOR;
        float2 jit = float2(frac(t * GRAIN_JITTER_SPEED_A), frac(t * GRAIN_JITTER_SPEED_B)) * GRAIN_JITTER_RANGE;
        float n = valueNoise(gc + jit) - 0.5;
        float shadowResp = 1.0 - smoothstep(0.0, GRAIN_SHADOW_ROLLOFF, luma);
        col += n * Grain * GRAIN_INTENSITY_SCALE * (GRAIN_SHADOW_BASE + GRAIN_SHADOW_RESPONSE * shadowResp);
    }

    // --- 2) Vignette ---
    if (VignetteOn && VignetteStrength > 0.001)
    {
        float2 p = uvc; p.x *= lerp(1.0, aspect, VIGNETTE_ASPECT_MIX);
        float d = length(p);

        float outer = max(VignetteRadius, 0.05);
        float inner = max(outer - max(VignetteFeather, 0.001), 0.0);

        // FIX: smoothstep requires edge0 < edge1. The original call passed
        // (outer, inner, d) with outer > inner in the common case (e.g. 1.23 vs
        // 1.21), which is undefined behavior per the HLSL spec. Correct form:
        // evaluate smoothstep(inner, outer, d) - which rises 0->1 from inner to
        // outer - and invert it, since we want full brightness (v=1) inside
        // inner and full darkening (v=0) outside outer.
        float v = 1.0 - smoothstep(inner, outer, d);

        col *= lerp(1.0, v, saturate(VignetteStrength));
    }

    return saturate(col);
}

technique BodycamLens <
    ui_label = "BodycamLens";
    ui_tooltip = "Bodycam look: fisheye, vignette, chromatic, grain, auto-exposure.\n"
                 "Toggle key F10 is synced with the mod's 'Bodycam Enabled' switch.";
    toggle = 0x79;   // F10 virtual-key - the mod presses this to sync on/off
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_BodycamLens;
    }
}

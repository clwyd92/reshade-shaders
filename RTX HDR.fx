// ============================================================================
//  RTX HDR.fx  –  RTX HDR-Emulation SDR into HDR inverse tone-mapper for ReShade
//
//  this shader uses Reshade to transform standard dynamic range games into high dynamic range (HDR)
//    ☆ Decode sRGB → linear BT.709
//    ☆ Black-floor crush (stops SDR greys looking washed out in HDR)
//    ☆ Expand chroma toward BT.2020 (gamut widening)
//    ☆ Saturation trim in linear light
//    ☆ Smooth highlight shoulder: pixels above SDR white get pushed
//       into super-white HDR range (PaperWhiteNits → PeakNits)
//    ☆ Output as scRGB (values > 1 = HDR super-white, requires
//       HDR swap-chain) OR as a Reinhard-preview SDR image.
//
//  FOR HDR OUTPUT:
//    ★ Enable Windows HDR (System → Display → HDR)
//    ★ Run the game / ReShade with RGBA16F back-buffer (scRGB colour space)
//    ★ Set Output Mode to "scRGB (HDR)"
//
//  FOR SDR DISPLAYS / PREVIEW:
//    ★ Set Output Mode to "SDR Preview" – the HDR range is tone-mapped
//      back to [0,1] so you can judge the effect on any monitor.
// ============================================================================

#include "ReShade.fxh"

// ============================================================================
// UI
// ============================================================================

uniform int OutputMode <
    ui_label   = "Output Mode";
    ui_tooltip = "scRGB  – outputs values above 1.0 (super-white) for HDR swap-chains.\n"
                 "SDR Preview – Reinhard-folds the result back to [0,1] for SDR monitors.";
    ui_type    = "combo";
    ui_items   = "scRGB (HDR)\0SDR Preview\0";
> = 0;

uniform float PaperWhiteNits <
    ui_label   = "Paper White (nits)";
    ui_tooltip = "How bright SDR 'white' (1.0) should appear in the HDR scene.\n"
                 "200-250 nits is a comfortable game default. 80 = broadcast standard.";
    ui_type    = "slider";
    ui_min     = 80.0; ui_max = 400.0; ui_step = 5.0;
> = 100.0;

uniform float PeakNits <
    ui_label   = "Peak Highlight (nits)";
    ui_tooltip = "Maximum luminance to push super-bright highlights to.\n"
                 "Match your display's rated HDR peak (e.g. 400, 600, 1000).";
    ui_type    = "slider";
    ui_min     = 400.0; ui_max = 2000.0; ui_step = 50.0;
> = 1000.0;

uniform float ShoulderStart <
    ui_label   = "Highlight Shoulder Start";
    ui_tooltip = "Luminance (fraction of SDR white) above which highlights begin to\n"
                 "expand into HDR range. RTX HDR typically uses ~0.7-0.8.";
    ui_type    = "slider";
    ui_min     = 0.4; ui_max = 0.95; ui_step = 0.01;
> = 0.75;

uniform float ShoulderStrength <
    ui_label   = "Highlight Shoulder Strength";
    ui_tooltip = "How far highlights are pushed above paper white.\n"
                 "RTX HDR default feel: 0.35-0.55. 1.0 = maximum lift.";
    ui_type    = "slider";
    ui_min     = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.45;

uniform float BlackFloor <
    ui_label   = "Black Floor Crush";
    ui_tooltip = "Tiny toe crush applied before expansion to stop near-black pixels\n"
                 "becoming grey in HDR. RTX HDR applies a subtle version of this.";
    ui_type    = "slider";
    ui_min     = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.01;

uniform float GamutExpansion <
    ui_label   = "Gamut Expansion (BT.2020)";
    ui_tooltip = "Blends chroma toward BT.2020 primaries, pushing saturated colours\n"
                 "beyond the sRGB/BT.709 gamut triangle – the colour-widening that\n"
                 "RTX HDR performs. 0 = off (pure BT.709). 0.4-0.5 = Wide Colour Gamut.";
    ui_type    = "slider";
    ui_min     = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.50;

uniform float Saturation <
    ui_label   = "Saturation";
    ui_tooltip = "Applied in linear light before the inverse tone-map. 1.0 = unchanged.";
    ui_type    = "slider";
    ui_min     = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 1.02;

uniform float Exposure <
    ui_label   = "Exposure Adjust (EV)";
    ui_tooltip = "EV offset applied before expansion – useful when the game's SDR\n"
                 "image is slightly over or under-bright.";
    ui_type    = "slider";
    ui_min     = -2.0; ui_max = 2.0; ui_step = 0.05;
> = 0.0;

// ============================================================================
// Resources
// ============================================================================

texture2D texColor : COLOR;
sampler2D sColor { Texture = texColor; };

// ============================================================================
// Colour-science helpers
// ============================================================================

// Proper piecewise sRGB → linear (IEC 61966-2-1)
float3 srgb_to_linear(float3 c)
{
    c = max(c, 0.0);
    return (c <= 0.04045) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4);
}

// Linear → sRGB (for SDR preview path only)
float3 linear_to_srgb(float3 c)
{
    c = saturate(c);
    return (c <= 0.0031308) ? (c * 12.92) : (1.055 * pow(c, 1.0 / 2.4) - 0.055);
}

// BT.709 perceptual luminance
float luminance709(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Linear BT.709 → linear BT.2020 (same D65 white point, no CAT needed)
// ITU-R BT.2087 Table 3 matrix
float3 bt709_to_bt2020(float3 c)
{
    static const float3x3 M = float3x3(
        float3(0.6274040, 0.3292820, 0.0433136),
        float3(0.0690970, 0.9195400, 0.0113612),
        float3(0.0163916, 0.0880132, 0.8955950)
    );
    return mul(M, c);
}

// ============================================================================
//  Highlight Shoulder  (the core of RTX HDR's luminance expansion)
//
//  For luminance values above shoulderStart the curve smoothly lifts toward
//  peakScale using a Hermite (smoothstep) blend. Values below shoulderStart
//  are linear – preserving the SDR mid-tones untouched (key RTX HDR property).
// ============================================================================
float shoulder_expand(float x, float shoulderStart, float peakScale, float strength)
{
    if (x <= shoulderStart) return x;

    // Normalised position within the shoulder region [0, 1]
    float t = saturate((x - shoulderStart) / max(1.0 - shoulderStart, 1e-4));

    // Boosted destination: smoothly approach peakScale
    float boosted = shoulderStart + (peakScale - shoulderStart) * smoothstep(0.0, 1.0, t);

    // Blend: 0 strength = stay linear, 1 strength = full boost
    return lerp(x, boosted, strength);
}

// ============================================================================
//  Inverse Tone-Map:  SDR linear [0,1] → HDR nit-linear
//
//  scRGB convention: 1.0 == 80 nits (IEC 61966-2-2 reference white).
//  So PaperWhiteNits = 200 → SDR white maps to 200/80 = 2.5 in scRGB.
//  PeakNits = 1000 → peak highlight maps to 1000/80 ≈ 12.5 in scRGB.
// ============================================================================
float3 inverse_tonemap(float3 lin, float paperWhiteNits, float peakNits,
                       float shoulder, float strength)
{
    float paper_scale = paperWhiteNits / 80.0;   // SDR white in scRGB units
    float peak_scale  = peakNits       / 80.0;   // Peak highlight in scRGB units

    // Work luminance-preservingly: expand luma, reconstruct chroma
    float lum = luminance709(lin);

    // Expand luminance through shoulder
    float hdr_lum = shoulder_expand(lum, shoulder, 1.0, strength);

    // Scale the whole signal to paper white, with highlights going beyond
    // SDR white (lum > shoulder) getting an extra lift into HDR territory
    float base_scale   = paper_scale;
    float extra_scale  = (lum > 1e-6) ? (hdr_lum / max(lum, 1e-6)) : 1.0;
    // extra_scale >= 1: mid-tones stay at 1.0× paper-white, highlights rise
    // toward (peakScale/paper_scale) × paper_scale = peak_scale

    // Remap extra_scale so it can reach peak_scale at maximum
    // At lum==1 (SDR white), hdr_lum==1 after shoulder, so extra_scale==1.
    // The shoulder takes lum values in [shoulderStart,1] → [shoulderStart, 1] boosted.
    // We then map the overall output so SDR white = paper_scale,
    // and fully-boosted peak = peak_scale.
    float peak_boost   = (peak_scale / paper_scale);   // headroom multiplier
    float lift         = lerp(1.0, peak_boost, strength);
    // Reinterpret extra_scale in that range
    float final_scale  = base_scale * lerp(1.0, extra_scale * lift, 
                                           saturate((lum - shoulder) / max(1.0 - shoulder, 1e-4)));

    // Clamp to declared peak so we don't exceed the display's capability
    float3 result = lin * final_scale;
    float result_lum = luminance709(result);
    if (result_lum > peak_scale)
        result *= peak_scale / result_lum;

    return result;
}

// ============================================================================
// Pixel Shader
// ============================================================================

float4 HDRSimPS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    // 1. Fetch & decode sRGB → linear BT.709
    float3 lin = srgb_to_linear(tex2D(sColor, texcoord).rgb);

    // 2. Exposure offset
    lin *= exp2(Exposure);

    // 3. Black-floor crush – subtracts a tiny offset then renormalises
    //    This stops near-black SDR values from appearing as grey in HDR.
    lin = max(lin - BlackFloor, 0.0) / max(1.0 - BlackFloor, 1e-4);

    // 4. Gamut expansion BT.709 → BT.2020 blend
    //    Widens colour volume; saturated primaries (reds, greens, blues)
    //    move outward toward the BT.2020 primaries.
    float3 lin2020 = bt709_to_bt2020(lin);
    lin = lerp(lin, lin2020, GamutExpansion);

    // 5. Saturation (linear light, BT.709 luma anchor)
    float luma = luminance709(lin);
    lin = lerp(luma.xxx, lin, Saturation);
    lin = max(lin, 0.0);

    // 6. Inverse tone-map: expand into HDR nit-linear (scRGB scale)
    float3 hdr = inverse_tonemap(lin, PaperWhiteNits, PeakNits,
                                 ShoulderStart, ShoulderStrength);

    // 7. Output
    if (OutputMode == 0)
    {
        // scRGB: pass through directly.
        // Values > 1.0 are super-white and will display as HDR brightness
        // on an HDR10 / scRGB enabled swap-chain.
        return float4(hdr, 1.0);
    }
    else
    {
        // SDR Preview: soft-clip back to [0,1] with Reinhard at peak nits
        float peak_scale = PeakNits / 80.0;
        float3 preview   = hdr / (1.0 + hdr / peak_scale);
        return float4(linear_to_srgb(preview), 1.0);
    }
}

// ============================================================================
// Technique
// ============================================================================

technique RTX_HDR_Effect
<
    ui_label   = "RTX HDR>Emulation";
    ui_tooltip = "Emulates Nvidia RTX HDR: expands SDR content into HDR luminance\n"
                 "range and widens the colour gamut toward BT.2020.\n\n"
                 "REQUIRES HDR OUTPUT PATH:\n"
                 "  • Windows HDR enabled (System → Display → HDR)\n"
                 "  • Game / ReShade running with RGBA16F (scRGB) back-buffer\n\n"
                 "Use 'SDR Preview' mode to test the effect on SDR displays.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = HDRSimPS;
    }
}

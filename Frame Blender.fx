// ============================================================================
//  Frame Blender.fx - Reduces visible micro‑stutter and Low FPS juddering for Reshade
//  Temporal frame blending to simulate motion smoothing, helps to get a fake High FPS look.
//  Stores the previous frame, blends it with the current frame and creates a smoother, soft motion appearance.
// ============================================================================

#include "ReShade.fxh"

namespace FrameBlend
{
    // Timing
    uniform uint  FrameCount < source = "framecount"; >;
    uniform float FrameTime  < source = "frametime";  >;

    // User controls
    uniform uint TargetFPS <
        ui_type = "drag";
        ui_label = "Target Framerate";
        ui_min = 1; ui_max = 255;
        ui_tooltip = "Target framerate for motion blur calculation";
    > = 60;

    uniform float DropThreshold <
        ui_type = "drag";
        ui_label = "Frame Drop Threshold";
        ui_min = 0.0; ui_max = 2.0;
        ui_tooltip = "Sensitivity to frame drops";
    > = 1.125;

    uniform float BlurStrength <
        ui_type = "drag";
        ui_label = "Base Blur Strength";
        ui_min = 0.0; ui_max = 1.0;
        ui_tooltip = "Minimum blur amount in static areas";
    > = 0.0;

    uniform float MaxBlurStrength <
        ui_type = "drag";
        ui_label = "Max Blur Strength";
        ui_min = 0.0; ui_max = 2.0;
        ui_tooltip = "Maximum blur amount in high-motion areas";
    > = 1.0;

    uniform float MotionSensitivity <
        ui_type = "drag";
        ui_label = "Motion Sensitivity";
        ui_min = 0.0; ui_max = 10.0;
        ui_tooltip = "How quickly blur responds to motion";
    > = 2.0;

    // Depth-based controls
    uniform bool UseDepth <
        ui_label = "Enable Depth Detection";
        ui_tooltip = "Use depth buffer to detect and exclude UI elements";
    > = true;

    uniform float UIDepthThreshold <
        ui_type = "drag";
        ui_label = "UI Depth Threshold";
        ui_min = 0.0; ui_max = 1.0;
        ui_tooltip = "Depth value above which pixels are considered UI (usually 0.999+)";
    > = 0.999;

    uniform float DepthBlurScale <
        ui_type = "drag";
        ui_label = "Depth Blur Scaling";
        ui_min = 0.0; ui_max = 2.0;
        ui_tooltip = "How much depth affects blur strength (far = more blur)";
    > = 0.5;

    uniform bool ExcludeUI <
        ui_label = "Exclude UI from Blur";
        ui_tooltip = "Don't apply motion blur to UI elements";
    > = true;

    // Ping-pong textures
    texture2D AccumTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
    texture2D MetaTex  { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };

    sampler2D Accum { Texture = AccumTex; };
    sampler2D Meta  { Texture = MetaTex;  };

    // -------------------------------------------------------------
    // Accumulation pass with adaptive blur
    // -------------------------------------------------------------
    void Accumulate(in float4 vpos : SV_Position,
                    in float2 xy   : TEXCOORD,
                    out float4 outAccum : SV_Target0,
                    out float4 outMeta  : SV_Target1)
    {
        float4 prevAccum = tex2D(Accum, xy);
        float4 prevMeta  = tex2D(Meta,  xy);

        // Use full float precision for counter (stored in alpha)
        float prevCount = prevMeta.a;

        float4 cur = tex2D(ReShade::BackBuffer, xy);

        // ---------------------------------------------------------
        // Depth-based UI detection
        // ---------------------------------------------------------
        float depth = ReShade::GetLinearizedDepth(xy);
        bool isUI = (depth >= UIDepthThreshold);

        // If this is UI and we're excluding UI, bypass blur entirely
        if (ExcludeUI && isUI)
        {
            outAccum = float4(cur.rgb, FrameTime);
            outMeta  = float4(0.0, 0.0, 0.0, 0.0);
            return;
        }

        // ---------------------------------------------------------
        // Adaptive blur strength based on luminance motion
        // ---------------------------------------------------------
        float lumPrev = dot(prevAccum.rgb, float3(0.2126, 0.7152, 0.0722));
        float lumCur  = dot(cur.rgb,       float3(0.2126, 0.7152, 0.0722));

        float motion = abs(lumCur - lumPrev);

        // Color difference for better motion detection
        float3 colorDiff = abs(cur.rgb - prevAccum.rgb);
        float colorMotion = max(max(colorDiff.r, colorDiff.g), colorDiff.b);
        
        // Combine luma and color motion
        motion = max(motion, colorMotion * 0.5);

        float adaptive = saturate(motion * MotionSensitivity);

        // ---------------------------------------------------------
        // Depth-based blur scaling
        // ---------------------------------------------------------
        float depthScale = 1.0;
        if (UseDepth && !isUI)
        {
            // Far objects get more blur (depth approaches 1.0)
            depthScale = 1.0 + (depth * DepthBlurScale);
        }

        float blur = lerp(BlurStrength, MaxBlurStrength, adaptive) * depthScale;
        blur = max(blur, 0.001); // Prevent division by zero
        float invBlur = rcp(blur);

        // ---------------------------------------------------------
        // Frame drop compensation
        // ---------------------------------------------------------
        const float ms = 1000.0;
        float th = 1.0 + DropThreshold;

        float targetFrameTime = ms / float(TargetFPS);
        float lastN = (prevAccum.a / targetFrameTime) * th;
        float currN = (FrameTime / targetFrameTime) * th;

        currN = max(1.0, floor((currN + lastN * lastN) / (currN + lastN)));

        // ---------------------------------------------------------
        // Branchless accumulation with proper energy conservation
        // ---------------------------------------------------------
        float useNew = (prevCount < 0.5) ? 1.0 : 0.0;

        // Energy-conserving blend using linear space
        float totalWeight = prevCount + invBlur;
        float4 blended = (prevAccum * prevCount + cur * invBlur) / totalWeight;

        float4 accum = lerp(blended, cur, useNew);

        // ---------------------------------------------------------
        // Counter update
        // ---------------------------------------------------------
        bool reset = (prevCount >= (currN - 1.5));
        float newCount = reset ? 1.0 : prevCount + 1.0;

        // Clamp to reasonable range
        newCount = min(newCount, 255.0);

        outAccum = float4(accum.rgb, FrameTime);
        outMeta  = float4(motion, adaptive, blur, newCount);
    }

    // -------------------------------------------------------------
    // Final display pass
    // -------------------------------------------------------------
    void Display(in float4 vpos : SV_Position,
                 in float2 xy   : TEXCOORD,
                 out float4 outColor : SV_Target)
    {
        outColor = float4(tex2D(Accum, xy).rgb, 1.0);
    }

    #if __RESHADE__ >= 50000
    // Debug visualization (ReShade 5.0+)
    uniform int DebugMode <
        ui_type = "combo";
        ui_label = "Debug Visualization";
        ui_items = "Off\0Motion Heatmap\0Depth Map\0UI Mask\0Blur Strength\0";
        ui_tooltip = "Visualize different aspects of the effect";
    > = 0;

    void DisplayDebug(in float4 vpos : SV_Position,
                      in float2 xy   : TEXCOORD,
                      out float4 outColor : SV_Target)
    {
        if (DebugMode == 0)
        {
            // Normal output
            outColor = float4(tex2D(Accum, xy).rgb, 1.0);
        }
        else if (DebugMode == 1)
        {
            // Motion heatmap
            float4 meta = tex2D(Meta, xy);
            float adaptive = meta.g;
            float3 heatmap = float3(adaptive, 1.0 - adaptive, 0.0);
            outColor = float4(heatmap, 1.0);
        }
        else if (DebugMode == 2)
        {
            // Depth map
            float depth = ReShade::GetLinearizedDepth(xy);
            outColor = float4(depth.xxx, 1.0);
        }
        else if (DebugMode == 3)
        {
            // UI mask
            float depth = ReShade::GetLinearizedDepth(xy);
            bool isUI = (depth >= UIDepthThreshold);
            float3 mask = isUI ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
            outColor = float4(mask, 1.0);
        }
        else if (DebugMode == 4)
        {
            // Blur strength visualization
            float4 meta = tex2D(Meta, xy);
            float blurStrength = meta.b;
            outColor = float4(blurStrength.xxx, 1.0);
        }
    }
    #endif
}

technique FrameBlend
<
    ui_label = "Depth Aware Frame Blender";
    ui_tooltip = "Motion blur with depth detection and UI exclusion";
>
{
    pass AccumulatePass
    {
        VertexShader = PostProcessVS;
        PixelShader  = FrameBlend::Accumulate;
        RenderTarget0 = FrameBlend::AccumTex;
        RenderTarget1 = FrameBlend::MetaTex;
    }

    pass DisplayPass
    {
        VertexShader = PostProcessVS;
        #if __RESHADE__ >= 50000
        PixelShader  = FrameBlend::DisplayDebug;
        #else
        PixelShader  = FrameBlend::Display;
        #endif
    }
}
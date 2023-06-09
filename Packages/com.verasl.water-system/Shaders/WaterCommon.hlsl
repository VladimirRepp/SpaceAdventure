﻿#ifndef WATER_COMMON_INCLUDED
#define WATER_COMMON_INCLUDED

#define SHADOWS_SCREEN 0

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "WaterInput.hlsl"
#include "CommonUtilities.hlsl"
#include "GerstnerWaves.hlsl"
#include "WaterLighting.hlsl"

///////////////////////////////////////////////////////////////////////////////
//                  				Structs		                             //
///////////////////////////////////////////////////////////////////////////////

struct WaterVertexInput // vert struct
{
	float4	vertex 					: POSITION;		// vertex positions
	float2	texcoord 				: TEXCOORD0;	// local UVs
	UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct WaterVertexOutput // fragment struct
{
	float4	uv 						: TEXCOORD0;	// Geometric UVs stored in xy, and world(pre-waves) in zw
	float3	posWS					: TEXCOORD1;	// world position of the vertices
	half3 	normal 					: NORMAL;		// vert normals
	float3 	viewDir 				: TEXCOORD2;	// view direction
	float3	preWaveSP 				: TEXCOORD3;	// screen position of the verticies before wave distortion
	half2 	fogFactorNoise          : TEXCOORD4;	// x: fogFactor, y: noise
	float4	additionalData			: TEXCOORD5;	// x = distance to surface, y = distance to surface, z = normalized wave height, w = horizontal movement
	half4	shadowCoord				: TEXCOORD6;	// for ssshadows

	float4	clipPos					: SV_POSITION;
	UNITY_VERTEX_INPUT_INSTANCE_ID
	UNITY_VERTEX_OUTPUT_STEREO
};

///////////////////////////////////////////////////////////////////////////////
//          	   	       Water debug functions                             //
///////////////////////////////////////////////////////////////////////////////

half3 DebugWaterFX(half3 input, half4 waterFX, half screenUV)
{
    input = lerp(input, half3(waterFX.y, 1, waterFX.z), saturate(floor(screenUV + 0.7)));
    input = lerp(input, waterFX.xxx, saturate(floor(screenUV + 0.5)));
    half3 disp = lerp(0, half3(1, 0, 0), saturate((waterFX.www - 0.5) * 4));
    disp += lerp(0, half3(0, 0, 1), saturate(((1-waterFX.www) - 0.5) * 4));
    input = lerp(input, disp, saturate(floor(screenUV + 0.3)));
    return input;
}

///////////////////////////////////////////////////////////////////////////////
//          	   	      Water shading functions                            //
///////////////////////////////////////////////////////////////////////////////

half3 Scattering(half depth)
{
	return SAMPLE_TEXTURE2D(_AbsorptionScatteringRamp, sampler_AbsorptionScatteringRamp, half2(depth, 0.375h)).rgb;
}

half3 Absorption(half depth)
{
	return SAMPLE_TEXTURE2D(_AbsorptionScatteringRamp, sampler_AbsorptionScatteringRamp, half2(depth, 0.0h)).rgb;
}

float2 AdjustedDepth(half2 uvs, half4 additionalData)
{
	float rawD = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_ScreenTextures_linear_clamp, uvs);
	float d = LinearEyeDepth(rawD, _ZBufferParams);
	return float2(d * additionalData.x - additionalData.y, (rawD * -_ProjectionParams.x) + (1-UNITY_REVERSED_Z));
}

float3 WaterDepth(float3 posWS, half2 texcoords, half4 additionalData, half2 screenUVs)// x = seafloor depth, y = water depth
{
	float3 outDepth = 0;
	outDepth.xz = AdjustedDepth(screenUVs, additionalData);
	float wd = (1 - SAMPLE_TEXTURE2D_LOD(_WaterDepthMap, sampler_WaterDepthMap_linear_clamp, texcoords, 1).r) * 19.1;
	outDepth.y = (wd - 3.5) + posWS.y;
	return outDepth;
}

half3 Refraction(half2 distortion, half depth, real depthMulti)
{
	half3 output = SAMPLE_TEXTURE2D_LOD(_CameraOpaqueTexture, sampler_CameraOpaqueTexture_linear_clamp, distortion, depth * 0.25).rgb;
	output *= Absorption((depth) * depthMulti);
	return output;
}

half2 DistortionUVs(half depth, float3 normalWS)
{
    half3 viewNormal = mul((float3x3)GetWorldToHClipMatrix(), -normalWS).xyz;

    return viewNormal.xz * saturate((depth) * 0.005);
}

half4 AdditionalData(float3 postionWS, WaveStruct wave)
{
    half4 data = half4(0.0, 0.0, 0.0, 0.0);
    float3 viewPos = TransformWorldToView(postionWS);
	data.x = length(viewPos / viewPos.z);// distance to surface
    data.y = length(GetCameraPositionWS().xyz - postionWS); // local position in camera space
	data.z = wave.position.y / _MaxWaveHeight; // encode the normalized wave height into additional data
	data.w = wave.position.x + wave.position.z;
	return data;
}

WaterVertexOutput WaveVertexOperations(WaterVertexOutput input)
{
#if defined(_STATIC_WATER)
	float time = 0;
#else
	float time = _Time.y;
#endif

    input.normal = float3(0, 1, 0);
	input.fogFactorNoise.y = ((noise((input.posWS.xz * 0.5) + time) + noise((input.posWS.xz * 1) + time)) * 0.25 - 0.5) + 1;

	// Detail UVs
    input.uv.zw = input.posWS.xz * 0.1h + time * 0.05h + (input.fogFactorNoise.y * 0.1);
    input.uv.xy = input.posWS.xz * 0.4h - time.xx * 0.1h + (input.fogFactorNoise.y * 0.2);

	half4 screenUV = ComputeScreenPos(TransformWorldToHClip(input.posWS));
	screenUV.xyz /= screenUV.w;

    // shallows mask
    half waterDepth = (1 - SAMPLE_TEXTURE2D_LOD(_WaterDepthMap, sampler_WaterDepthMap_linear_clamp, (input.posWS.xz * 0.002) + 0.5, 1).r) * 19.1;
    waterDepth = waterDepth - 4.1;
    input.posWS.y += saturate((1-waterDepth) * 0.6 - 0.5);

	//Gerstner here
	WaveStruct wave;
	SampleWaves(input.posWS, saturate((waterDepth * 0.25)) + 0.05, wave);
	input.normal = wave.normal.xzy;
    input.posWS += wave.position;

#ifdef SHADER_API_PS4
	input.posWS.y -= 0.5;
#endif

    // Dynamic displacement
	half4 waterFX = SAMPLE_TEXTURE2D_LOD(_WaterFXMap, sampler_ScreenTextures_linear_clamp, screenUV.xy, 0);
	input.posWS.y += waterFX.w * 2 - 1;

	// After waves
	input.clipPos = TransformWorldToHClip(input.posWS);
	input.shadowCoord = ComputeScreenPos(input.clipPos);
    input.viewDir = SafeNormalize(_WorldSpaceCameraPos - input.posWS);

    // Fog
	input.fogFactorNoise.x = ComputeFogFactor(input.clipPos.z);
	input.preWaveSP = screenUV.xyz; // pre-displaced screenUVs

	// Additional data
	input.additionalData = AdditionalData(input.posWS, wave);

	// distance blend
	half distanceBlend = saturate(abs(length((_WorldSpaceCameraPos.xz - input.posWS.xz) * 0.005)) - 0.25);
	input.normal = lerp(input.normal, half3(0, 1, 0), distanceBlend);

	return input;
}

///////////////////////////////////////////////////////////////////////////////
//               	   Vertex and Fragment functions                         //
///////////////////////////////////////////////////////////////////////////////

// Vertex: Used for Standard non-tessellated water
WaterVertexOutput WaterVertex(WaterVertexInput v)
{
    WaterVertexOutput o;// = (WaterVertexOutput)0;
	UNITY_SETUP_INSTANCE_ID(v);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
	UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

    o.uv.xy = v.texcoord; // geo uvs
    o.posWS = TransformObjectToWorld(v.vertex.xyz);

	o = WaveVertexOperations(o);
    return o;
}

// Fragment for water
half4 WaterFragment(WaterVertexOutput IN) : SV_Target
{
	UNITY_SETUP_INSTANCE_ID(IN);
	half3 screenUV = IN.shadowCoord.xyz / IN.shadowCoord.w;//screen UVs

	half4 waterFX = SAMPLE_TEXTURE2D(_WaterFXMap, sampler_ScreenTextures_linear_clamp, IN.preWaveSP.xy);

	// Depth
	float3 depth = WaterDepth(IN.posWS, (IN.posWS.xz * 0.002) + 0.5, IN.additionalData, screenUV.xy);// TODO - hardcoded shore depth UVs
	half depthMulti = 1 / _MaxDepth;

	// Lighting
	half2 jitterUV = screenUV.xy * _ScreenParams.xy * _DitherPattern_TexelSize.xy;
#ifndef _STATIC_WATER
    jitterUV += frac(_Time.zw);
#endif
	float3 jitterTexture = SAMPLE_TEXTURE2D(_DitherPattern, sampler_DitherPattern, jitterUV).xyz * 2 - 1;
	float3 lightJitter = IN.posWS + jitterTexture.xzy * 2.5;
	Light mainLightJittered = GetMainLight(TransformWorldToShadowCoord(lightJitter));
	Light mainLight = GetMainLight(TransformWorldToShadowCoord(IN.posWS));
    half shadow = mainLightJittered.shadowAttenuation;
    half3 GI = SampleSH(IN.normal);

    // SSS
    half3 sss = 1 * (shadow * mainLight.color + GI);

	// Foam
	half3 foamMap = SAMPLE_TEXTURE2D(_FoamMap, sampler_FoamMap,  IN.uv.zw).rgb; //r=thick, g=medium, b=light
	half waveFoam = saturate(IN.posWS.y + 0.5);
	half edgeFoam = saturate(1 - depth.x * 0.5 - 0.25);
	half foamBlendMask = max(max(waveFoam, edgeFoam), waterFX.r * 2);// + IN.fogFactorNoise.y * 0.1; //max(max((foamMask + shoreMask) - IN.fogFactorNoise.y * 0.25, waterFX.r * 2), shoreWave);
	half3 foamBlend = SAMPLE_TEXTURE2D(_AbsorptionScatteringRamp, sampler_AbsorptionScatteringRamp, half2(foamBlendMask, 0.66)).rgb;
	half foamMask = saturate(length(foamMap * foamBlend) * 1.5 - 0.1 + saturate(1 - depth.x * 4) * 0.5);
	// Foam lighting
	half3 foam = foamMask.xxx * (mainLight.shadowAttenuation * mainLight.color + GI);

	// Detail waves
	half2 detailBump1 = SAMPLE_TEXTURE2D(_SurfaceMap, sampler_SurfaceMap, IN.uv.zw).xy * 2 - 1;
	half2 detailBump2 = SAMPLE_TEXTURE2D(_SurfaceMap, sampler_SurfaceMap, IN.uv.xy).xy * 2 - 1;
	half2 detailBump = (detailBump1 + detailBump2 * 0.5) * saturate(depth.x * 0.25 + 0.25);

	IN.normal += half3(detailBump.x, 0, detailBump.y) * _BumpScale;
	IN.normal += half3(1-waterFX.y, 0.5h, 1-waterFX.z) - 0.5;
	IN.normal = normalize(IN.normal);

	// Distortion
	half2 distortion = DistortionUVs(depth.x, IN.normal);
	distortion = screenUV.xy + distortion;// * clamp(depth.x, 0, 5);
	float d = depth.x;
	depth.xz = AdjustedDepth(distortion, IN.additionalData);
	distortion = depth.x < 0 ? screenUV.xy : distortion;
	depth.x = depth.x < 0 ? d : depth.x;

	// Fresnel
	half fresnelTerm = CalculateFresnelTerm(IN.normal, IN.viewDir.xyz);

    BRDFData brdfData;
    InitializeBRDFData(half3(0, 0, 0), 0, half3(1, 1, 1), 0.9, 1, brdfData);
	half3 spec = DirectBDRF(brdfData, IN.normal, mainLight.direction, IN.viewDir) * shadow * mainLight.color;
#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, IN.posWS);
        spec += LightingPhysicallyBased(brdfData, light, IN.normal, IN.viewDir);
        sss += light.distanceAttenuation * light.color;
    }
#endif

    sss *= Scattering(depth.x * depthMulti);

	// Reflections
	half3 reflection = SampleReflections(IN.normal, IN.viewDir.xyz, screenUV.xy, fresnelTerm, 0.0);
	reflection = clamp(reflection + spec, 0, 1024);

	// Refraction
	half3 refraction = Refraction(distortion, depth.x, depthMulti);

	// Final Colouring
    half3 diffuse = refraction + sss;

	// Do compositing
	half3 comp = lerp(reflection + diffuse, foam, foamMask); //lerp(refraction, color + reflection + foam, 1-saturate(1-depth.x * 25));

	// Fog
    float fogFactor = IN.fogFactorNoise.x;
    comp = MixFog(comp, fogFactor);
    //comp = DebugWaterFX(comp, waterFX, screenUV.x);
	return half4(comp, 1);
	//return SAMPLE_TEXTURE2D(_PlanarReflectionTexture, sampler_ScreenTextures_linear_clamp, screenUV);
	//return half4(spec, 1); // debug line
	//return half4(diffuse, 1); // debug line
	//return half4( (1 - foamMask).xxx, 1); // debug line
	//eturn half4(pow(dot(IN.normal,float3(0, 1, 0)), 10).xxx, 1); // debug line
}

#endif // WATER_COMMON_INCLUDED
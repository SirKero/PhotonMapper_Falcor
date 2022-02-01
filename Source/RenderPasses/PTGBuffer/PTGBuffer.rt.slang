#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Experimental.Scene.Material.StandardMaterial;
import Experimental.Scene.Material.MaterialHelpers;
import Experimental.Scene.Lights.LightHelpers;


cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
}

// Outputs
RWTexture2D<float4> gOutput;
RWTexture2D<float4> gPosW;
RWTexture2D<float4> gNormW;
RWTexture2D<float4> gTangentW;
RWTexture2D<float4> gTexC;
RWTexture2D<float4> gDiffuseOpacity;
RWTexture2D<float4> gSpecRough;
RWTexture2D<float4> gEmissive;
RWTexture2D<float4> gMatlExtra;
RWTexture2D<float4> gViewWorld;
RWTexture2D<float4> gFaceNormal;

static const uint kMaxRecursion = MAX_RECURSION;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

/** Payload for scatter ray (80B).
*/
struct ScatterRayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    bool terminated; ///< Set to true when path is terminated.
    float3 thp; ///< Current path throughput. This is updated at each path vertex.
    uint pathLength; ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin; ///< Next path segment origin.
    uint lobeType; ///< Mask for the type of reflection
    float3 direction; ///< Next path segment direction.
    uint _pad1;

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static ScatterRayData create()
    {
        ScatterRayData d;
        d.terminated = false;
        d.lobeType = 0;
        d.pathLength = 0;
        d.radiance = float3(1, 1, 1);
        d.thp = float3(1, 1, 1);
        d.origin = float3(0, 0, 0);
        d.direction = float3(0, 0, 0);
        return d;
    }
};


[shader("miss")]
void miss(inout ScatterRayData rayData : SV_RayPayload)
{
    rayData.terminated = true;

    //TODO: Add enviroment map color if ray misses scene
    if (kUseEnvBackground)
    {
        float3 Le = gScene.envMap.eval(WorldRayDirection());
        rayData.radiance *= Le;
    }
    else
    {
        rayData.radiance = 0;
    }

}


[shader("closesthit")]
void closestHit(inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
   // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), 0.f);

    float pdf = 0.f;
    uint lobe = 0;
    float3 wiLocal = sd.toLocal(sd.V);
    float3 woLocal = { }, weight = { };

    FalcorBSDF bsdf;
    bsdf.setup(sd);
    bool valid = bsdf.sample(wiLocal, woLocal, pdf, weight, lobe, rayData.sg);

    float3 res = bsdf.eval(wiLocal, woLocal) * weight; //TODO: Check if order is correct

    bool transmission = (lobe & (uint) LobeType::Transmission) > 0;
    bool isDelta = (lobe & (uint) LobeType::Delta) > 0;
    //compute ray origin for the new ray
    float3 rayOrigin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    bool diffuseHit = (lobe & (uint) LobeType::DiffuseReflection) > 0;
    
    rayData.radiance *= weight;
    //set ray data
    rayData.origin = rayOrigin;
    rayData.direction = sd.fromLocal(woLocal);
    rayData.thp = valid ? isDelta ? float3(1.0) : res / pdf : float3(0);
    rayData.lobeType = lobe; //save lobe type
    rayData.thp = min(max(rayData.thp, float3(0)), float3(1.0)); //there is a low probabilty that transmission creates a valid ray with broken thp
    //if throughput is 0, return
    if (!any(rayData.thp > 0.f))
    {
        rayData.terminated = true;
    }
        

    //save hit if lobe is diffuse
    if ((lobe & ((uint) LobeType::Specular | (uint) LobeType::Delta)) == 0 && !rayData.terminated)
    {
        uint specTrans16 = f32tof16(sd.specularTransmission) << 16;
        uint diffTrans16 = f32tof16(sd.diffuseTransmission);
        uint trans16 = specTrans16 | diffTrans16;
        
        gPosW[launchIndex] = float4(rayOrigin, 1.0);
        gNormW[launchIndex] = float4(sd.N, 1.0);
        gTangentW[launchIndex] = float4(sd.T, 1.0);
        gTexC[launchIndex] = float4(sd.uv, 1.0, 1.0);
        gDiffuseOpacity[launchIndex] = float4(sd.diffuse * rayData.radiance, sd.opacity);
        gSpecRough[launchIndex] = float4(sd.specular * rayData.radiance, sd.linearRoughness);
        gEmissive[launchIndex] = float4(sd.emissive * rayData.radiance, 1.0);
        gMatlExtra[launchIndex] = float4(sd.IoR, asfloat(sd.flags), asfloat(trans16), sd.metallic);
        gViewWorld[launchIndex] = float4(-WorldRayDirection(), 1.0);
        gFaceNormal[launchIndex] = float4(sd.faceN, 1);
    }
    
    rayData.pathLength++;
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    float3 outColor = float3(0);
    float3 throughput = float3(1);
    ScatterRayData rayData = ScatterRayData.create();
    rayData.sg = SampleGenerator.create(launchIndex, gFrameCount); //lazy init for now
    Ray ray = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg)); //get a random jittered ray
    uint rayFlags = 0;
    
    //Trace recursive
    for (uint i = 0; i < kMaxRecursion; i++)
    {
        
        
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray.toRayDesc(), rayData);

        if (rayData.terminated)
            break;

        throughput *= rayData.thp; //accumulate throughput
        
        //calculate color and stop if we are diffuse
        if (((uint) LobeType::Diffuse & rayData.lobeType) > 0)
        {
            break;
        }
        
        //update ray for next iteration
        ray.origin = rayData.origin;
        ray.dir = rayData.direction;
    }

    outColor = rayData.radiance * throughput;
    gOutput[launchIndex] = float4(outColor, 1);

}

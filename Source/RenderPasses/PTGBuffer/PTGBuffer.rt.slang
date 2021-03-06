#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Geometry.GeometryHelpers;
import Scene.Material.ShadingUtils;


cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gSpecularRougnessCutoff;  //cutoff for when a hit counts as diffuse
    float gEmissiveCutoff;          //if a emissive material is over this value hit is counted as diffuse emissive
}

// Outputs
RWTexture2D<float4> gPosW;
RWTexture2D<float4> gNormW;
RWTexture2D<float4> gTangentW;
RWTexture2D<float4> gTexC;
RWTexture2D<float4> gViewWorld;
RWTexture2D<float4> gFaceNormal;
RWTexture2D<float4> gThpMatID;
RWTexture2D<float4> gEmissive;

static const uint kMaxRecursion = MAX_RECURSION;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

/** Payload for scatter ray (64B).
*/
struct ScatterRayData
{
    float3 thp; ///< Current path throughput. This is updated at each path vertex.
    bool terminated; ///< Set to true when path is terminated.
    float3 origin; ///< Next path segment origin.
    uint lobeType; ///< Mask for the type of reflection
    float3 direction; ///< Next path segment direction.
    uint pathLength;       ///free space

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    __init(SampleGenerator sg){
        this.thp = float3(1.0);
        this.terminated = false; 
        this.origin = float3(0); 
        this.lobeType = 0; 
        this.direction = float3(0); 
        this.pathLength = 0;
        this.sg = sg;
    }
};

//TODO: Add other miss colors, as throughput then has to be respected
[shader("miss")]
void miss(inout ScatterRayData rayData : SV_RayPayload)
{
    rayData.terminated = true;
}


[shader("closesthit")]
void closestHit(inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
   // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -WorldRayDirection(), lod);

    adjustShadingNormal(sd, v);
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    
    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);    
    
    float3 thpStart = rayData.thp;
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    rayData.origin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    rayData.thp *= valid ? bsdfSample.weight : float3(0);
    rayData.lobeType = bsdfSample.lobe;
    rayData.direction = bsdfSample.wo;

    //get material properties
    let bsdfProperties = bsdf.getProperties(sd);

    bool isDiffuse = bsdfProperties.roughness > gSpecularRougnessCutoff;
    isDiffuse |= any(bsdfProperties.emission > gEmissiveCutoff);

    //if ray is invalid terminate
    rayData.terminated = !valid;
    
    //save hit if lobe is diffuse
    if ((bsdfSample.isLobe(LobeType::DiffuseReflection) || (bsdfSample.isLobe(LobeType::Reflection) && isDiffuse)) && (!rayData.terminated || isDiffuse))
    {
        // We store the final normal and tangent in the G-buffer.
         // In order to reconstruct the bitangent later, we also need to store its handedness (sign).
        float3 B = cross(sd.N, sd.T);
        float bitangentSign = dot(sd.B, B) >= 0.f ? 1.f : -1.f;

        gPosW[launchIndex] = float4(rayData.origin, 1.0);
        gNormW[launchIndex] = float4(sd.N, 1.0);
        gTangentW[launchIndex] = float4(sd.T, bitangentSign);
        gTexC[launchIndex] = float4(sd.uv, 1.0, 1.0);
        gViewWorld[launchIndex] = float4(-WorldRayDirection(), 1);
        gFaceNormal[launchIndex] = float4(sd.faceN, 1);
        gThpMatID[launchIndex] = float4(thpStart, asfloat(sd.materialID));

        // Get BSDF properties.
        
        //float emissiveFactor = rayData.pathLength > 0 ? 0.5 / rayData.pathLength : 1.0;
        gEmissive[launchIndex] = float4(bsdfProperties.emission, 0.f);
        rayData.terminated = true;
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
    ScatterRayData rayData = ScatterRayData(SampleGenerator(launchIndex, gFrameCount)); //lazy init for now
    Ray ray = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg)); //get a random jittered ray
    uint rayFlags = 0;
    
    //Trace recursive
    for (uint i = 0; i < kMaxRecursion; i++)
    {
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray.toRayDesc(), rayData);

        //if ray is invalid return
        if (rayData.terminated)
            return;
      
        //update ray for next iteration
        ray.origin = rayData.origin;
        ray.dir = rayData.direction;
    }
}

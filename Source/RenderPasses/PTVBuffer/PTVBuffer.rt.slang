#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Geometry.GeometryHelpers;


cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gSpecularRougnessCutoff;  //cutoff for when a hit counts as diffuse
    float gEmissiveCutoff;          //if a emissive material is over this value hit is counted as diffuse emissive
}

// Outputs
RWTexture2D<PackedHitInfo> gVBuffer;
RWTexture2D<float4> gViewWorld;
RWTexture2D<float4> gThp;
RWTexture2D<float4> gEmissive;

//Optional
RWTexture2D<float4> gDepth;
RWTexture2D<float4> gMotionVector;

#define is_valid(name) (is_valid_##name != 0)

static const uint kMaxRecursion = MAX_RECURSION;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const bool kAdjustShadingNormals = ADJUST_SHADING_NORMALS;
static const bool kUseAlphaTest = USE_ALPHA_TEST;
static const bool kComputeDepthOfField = COMPUTE_DEPTH_OF_FIELD;

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

void writeHit(uint2 pixel, float3 rayDir, float3 thp, float3 emissive, const HitInfo hit)
{
    gVBuffer[pixel] = hit.getData();
    gViewWorld[pixel] = float4(rayDir, 1);
    gThp[pixel] = float4(thp, 1);
    gEmissive[pixel] = float4(emissive, 1);

    //TODO: calculate these values
    if (is_valid(gDepth)) gDepth[pixel] = 1.f;
    if (is_valid(gMotionVector)) gMotionVector[pixel] = {};
}

void writeMiss(uint2 pixel)
{
    gVBuffer[pixel] = { };

    if (is_valid(gDepth)) gDepth[pixel] = 1.f;
    if (is_valid(gMotionVector)) gMotionVector[pixel] = { };
}

//TODO: Add other miss colors, as throughput then has to be respected
[shader("miss")]
void miss(inout ScatterRayData rayData : SV_RayPayload)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    rayData.terminated = true;
    writeMiss(launchIndex);
}

//add anyHit shader for alpha test

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
        //Get hit information for vbuffer
        TriangleHit triangleHit;
        triangleHit.instanceID = getGeometryInstanceID();
        triangleHit.primitiveIndex = PrimitiveIndex();
        triangleHit.barycentrics = attribs.barycentrics;
        
        writeHit(launchIndex, -WorldRayDirection(), thpStart, bsdfProperties.emission, HitInfo(triangleHit));
        
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

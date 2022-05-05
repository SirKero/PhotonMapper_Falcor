#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Scene.Material.ShadingUtils;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.BasicMaterialData;
import Scene.Material.MaterialSystem;
import Rendering.Materials.InteriorList;
import Rendering.Materials.InteriorListHelpers;
//import Rendering.Volumes.HomogeneousVolumeSampler; //Add maybe if dielectrics work
import Rendering.Lights.LightHelpers;
import Utils.Geometry.GeometryHelpers;


cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
}

cbuffer CB
{
    uint gMaxRecursion;     //Maximum length a path can travel
    float gSpecularRougnessCutoff; //cutoff for when a hit counts as diffuse
    float gEmissiveCutoff; //if a emissive material is over this value hit is counted as diffuse emissive
    bool gAdjustShadingNormals; //Adjusts the shading normals if activated

    bool gUseAlphaTest;     //uses alpha test if activated
};

// Outputs
RWTexture2D<PackedHitInfo> gVBuffer;
RWTexture2D<float4> gViewWorld;
RWTexture2D<float4> gThp;
RWTexture2D<float4> gEmissive;

//Optional
RWTexture2D<float4> gDepth;
RWTexture2D<float4> gMotionVector;

#define is_valid(name) (is_valid_##name != 0)

static const bool kComputeDepthOfField = COMPUTE_DEPTH_OF_FIELD;
static const uint kMaxRejectedHits = 8;

/** Payload for scatter ray (72B).
*/
struct RayData
{
    float3 thp; ///< Current path throughput. This is updated at each path vertex.
    bool terminated; ///< Set to true when path is terminated.
    float3 origin; ///< Next path segment origin.
    uint pathLength; ///<Path length
    float3 direction; ///< Next path segment direction.
    uint rejectedHits;       ///number of rejected hits (for dielectrics)

    InteriorList interiorList;  ///< interior list (8B)
    uint2 pad;
    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    __init(SampleGenerator sg){
        this.thp = float3(1.0);
        this.terminated = false; 
        this.origin = float3(0); 
        this.pathLength = 0; 
        this.direction = float3(0); 
        this.rejectedHits = 0;
        this.sg = sg;
    }
};

//For handling Nested Dielectrics. Taken from Path Tracer pass
bool handleNestedDielectrics(inout ShadingData sd, inout RayData rayData)
{
    uint nestedPriority = sd.mtl.getNestedPriority();
    
    if (!rayData.interiorList.isTrueIntersection(nestedPriority))
    {
        // If it is a false intersection, we reject the hit and continue the path
        // on the other side of the interface.
        // If the offset position is not quite large enough, due to self-intersections
        // it is possible we repeatedly hit the same surface and try to reject it.
        // This has happened in a few occasions with large transmissive triangles.
        // As a workaround, count number of rejected hits and terminate the path if too many.
        if (rayData.rejectedHits < kMaxRejectedHits)
        {
            rayData.rejectedHits++;
            rayData.interiorList.handleIntersection(sd.materialID, nestedPriority, sd.frontFacing);
            rayData.origin = sd.computeNewRayOrigin(false);
        }
        else
        {
            rayData.terminated = true;
        }
        return false;
    }
    
    // Compute index of refraction for medium on the outside.
    //TODO: This does not work, gpu stops working 
    //sd.IoR = computeOutsideIoR(rayData.interiorList, sd.materialID, sd.frontFacing);
    
    return true;
}

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
void miss(inout RayData rayData : SV_RayPayload)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    rayData.terminated = true;
    writeMiss(launchIndex);
}

//add anyHit shader for alpha test
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
   // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -WorldRayDirection(), lod);

    if (gAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }

    // Reject false hits in nested dielectrics.
    //if (!handleNestedDielectrics(sd, rayData)) return;
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    
    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);    
    
    float3 thpStart = rayData.thp;
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    rayData.origin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    rayData.thp *= valid ? bsdfSample.weight : float3(0);
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
        
        writeHit(launchIndex, WorldRayDirection(), thpStart, bsdfProperties.emission * bsdfSample.weight, HitInfo(triangleHit));
        
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
    RayData rayData = RayData(SampleGenerator(launchIndex, gFrameCount)); //lazy init for now
    Ray ray = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg)); //get a random jittered ray
    uint rayFlags = 0;
    
    //Trace recursive
    for (uint i = 0; i < gMaxRecursion; i++)
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

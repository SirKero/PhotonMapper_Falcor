#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Scene.Camera.CameraData;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Geometry.GeometryHelpers;
import Scene.Material.ShadingUtils;
import Rendering.Materials.InteriorList;
import Rendering.Materials.InteriorListHelpers;
//import Rendering.Volumes.HomogeneousVolumeSampler; //Add maybe if dielectrics work
import Rendering.Lights.LightHelpers;



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
    bool gUseRandomPixelPosCamera;  //Uses a randomly generated pixel offset for camera direction sampeling instead of fixed jitter
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

/** Computes a camera ray for a given pixel assuming a thin-lens camera model with a random instead of a fixed jitter. Based on computeRandomRayThinlens()
        The camera jitter is taken into account to compute the sample position on the image plane.
        \param[in] pixel Pixel coordinates with origin in top-left.
        \param[in] frameDim Image plane dimensions in pixels.
        \param[in] u Uniform 2D sample. Used for pixel pos.
        \param[in] v Uniform 2D sample. Used for thin lens sample.
        \param[in] data Camera data.
        \return Returns the camera ray.
    */
Ray cameraComputeRandomRayThinlens(uint2 pixel, uint2 frameDim, float2 u , float2 v, in const CameraData data)
{
    Ray ray;

    // Sample position in screen space in [0,1] with origin at the top-left corner.
    // The camera jitter offsets the sample by +-0.5 pixels from the pixel center.
    float2 p = (pixel + u) / frameDim;
    float2 ndc = float2(2, -2) * p + float2(-1, 1);

    // Compute the normalized ray direction assuming a thin-lens camera.
    ray.origin = data.posW;
    ray.dir = ndc.x * data.cameraU + ndc.y * data.cameraV + data.cameraW;
    float2 apertureSample = sample_disk(u); // Sample lies in the unit disk [-1,1]^2
    float3 rayTarget = ray.origin + ray.dir;
    ray.origin += data.apertureRadius * (apertureSample.x * normalize(data.cameraU) + apertureSample.y * normalize(data.cameraV));
    ray.dir = normalize(rayTarget - ray.origin);

    float invCos = 1.f / dot(normalize(data.cameraW), ray.dir);
    ray.tMin = data.nearZ * invCos;
    ray.tMax = data.farZ * invCos;

    return ray;
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

bool generateNewRay(const ShadingData sd, const IBSDF bsdf, float3 rayOrigin, inout BSDFSample bsdfSample, inout RayData rayData)
{
    // Sample material.
    if (bsdf.sample(sd, rayData.sg, bsdfSample, true /*Importance Sampeling*/))
    {
        rayData.origin = rayOrigin;
        rayData.direction = bsdfSample.wo;
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            //rayData.origin = computeRayOrigin(sd.posW, dot(sd.faceN, bsdfSample.wo) <= 0.f ? -sd.faceN : sd.faceN);
            rayData.origin = sd.posW;
        }
        
        rayData.thp *= bsdfSample.weight;
        return any(rayData.thp > 0.f);
    }

    return false;
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    uint2 launchIndex = DispatchRaysIndex().xy;
   // Evaluate Falcor's material parameters at the hit point.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayData.direction, lod);

    
    if (gAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    
    // Reject false hits in nested dielectrics.
    //if (!handleNestedDielectrics(sd, rayData)) return;
    float3 thpStart = rayData.thp;
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
        
    if (!generateNewRay(sd, bsdf, sd.computeNewRayOrigin(), bsdfSample, rayData))
    {
        rayData.terminated = true;
        return;
    }

    //get material properties
    let bsdfProperties = bsdf.getProperties(sd);

    bool isDiffuse = bsdfProperties.roughness > gSpecularRougnessCutoff;
    isDiffuse |= any(bsdfProperties.emission > gEmissiveCutoff);
       
    //save hit if lobe is diffuse
    if ((bsdfSample.isLobe(LobeType::DiffuseReflection) || (bsdfSample.isLobe(LobeType::Reflection) && isDiffuse)) && (!rayData.terminated || isDiffuse))
    {        
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
    Ray camRay;
    if (gUseRandomPixelPosCamera)
    {
        camRay = cameraComputeRandomRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg), sampleNext2D(rayData.sg), gScene.camera.data);
    }
    else
    {
        camRay = gScene.camera.computeRayThinlens(launchIndex, launchDim, sampleNext2D(rayData.sg)); //get jittered ray
    }
   
    uint rayFlags = 0;
    RayDesc ray;
    ray.Origin = camRay.origin;
    ray.Direction = camRay.dir;
    ray.TMax = camRay.tMax;
    ray.TMin = camRay.tMin;

    rayData.origin = ray.Origin;
    rayData.direction = ray.Direction;
    
    //Trace recursive
    for (uint i = 0; i < gMaxRecursion; i++)
    {
        TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        //if ray is invalid return
        if (rayData.terminated)
            return;
      
        //update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
    }
}

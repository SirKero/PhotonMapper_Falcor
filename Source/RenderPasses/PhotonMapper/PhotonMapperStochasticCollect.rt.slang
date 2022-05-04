#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
//import Experimental.Scene.Material.MaterialHelpers;
import Rendering.Lights.LightHelpers;


cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
    float gCausticRadius;   // Radius for the caustic photons
    float gGlobalRadius;    // Radius for the global photons
}

cbuffer CB
{
    float gEmissiveScale; // Scale for the emissive part
    bool gCollectGlobalPhotons;
    bool gCollectCausticPhotons;
};

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewWorld;
Texture2D<float4> gThpMatID;
Texture2D<float4> gEmissive;


// Outputs
RWTexture2D<float4> gPhotonImage;

//Acceleration Structure
RaytracingAccelerationStructure gPhotonAS;

//Internal Buffer Structs

struct PhotonInfo
{
    float3 dir;
    float faceNTheta;
    float3 flux;
    float faceNPhi;
};

 //Internal Buffer Structs

Texture2D<float4> gCausticFlux;
Texture2D<float4> gCausticDir;
Texture2D<float4> gGlobalFlux;
Texture2D<float4> gGlobalDir;
StructuredBuffer<AABB> gCausticAABB;
StructuredBuffer<AABB> gGlobalAABB;

// Static configuration based on defines set from the host.
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

static const uint kInfoTexHeight = INFO_TEXTURE_HEIGHT;

static const float kRayTMin = RAY_TMIN;
static const float kRayTMax = RAY_TMAX;

/** Payload for ray (16 * X B).
*/
struct RayData
{
    uint counter;                   //Counter for photons this pixel
    uint photonIdx[NUM_PHOTONS];    //Num Photons, variable length

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
};

//Encode Normal + Face Normal
uint3 encodeNormalFaceNormal(in float3 normal, in float3 faceNormal)
{
    uint3 normal16 = f32tof16(normal) << 16;
    uint3 faceNormal16 = f32tof16(faceNormal);
    return (normal16 | faceNormal16);
}

//Decode Normal + Face Normal
void decodeNormalFaceNormal(in uint3 encodedNormal, out float3 normal, out float3 faceNormal)
{
    faceNormal = f16tof32(encodedNormal & 0xffff);
    normal = f16tof32(encodedNormal >> 16);
}

struct SphereAttribs
{
    float2 pad;
};

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    return gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    // Nothing happens here. Just here for completions sake
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{
    // Nothing happens here. Just here for completions sake
}


[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{
    const uint primIndex = PrimitiveIndex();
    rayData.counter++;
    uint idx = rayData.counter -1;
    //If idx is bigger get a random index between 0 and idx
    if (idx >= NUM_PHOTONS)
    {
        idx = uint(sampleNext1D(rayData.sg) * (idx + 1));
    }
    //insert 
    if (idx < NUM_PHOTONS)
        rayData.photonIdx[idx] = primIndex;
}

//Checks if the ray start point is inside the sphere. 0 is returned if it is not in sphere and 1 if it is
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

[shader("intersection")]
void intersection()
{
    
    //Check for Sphere intersection
    const float3 origin = ObjectRayOrigin();
    const uint primIndex = PrimitiveIndex();
    
    AABB photonAABB;
    float radius = 0;
    //Instance 0 is always the caustic buffer
    if (InstanceIndex() == 0)
    {
        photonAABB = gCausticAABB[primIndex];
        radius = gCausticRadius;
    }
    else
    {
        photonAABB = gGlobalAABB[primIndex];
        radius = gGlobalRadius;
    }
        
    bool tHit = hitSphere(photonAABB.center(), radius, origin);

    SphereAttribs attribs;
    attribs.pad = float2(0);
    
    if (tHit)
    {
        ReportHit(RayTCurrent(), 0, attribs);
    }
}

float3 photonContribution(in const ShadingData sd, in IBSDF bsdf, inout RayData rayData, bool isCaustic)
{
    uint maxIdx = min(rayData.counter, NUM_PHOTONS);
    float3 radiance = float3(0);
    
    if (maxIdx == 0)
        return radiance;
    
    for (uint i = 0; i < maxIdx; i++)
    {
        uint photonIdx = rayData.photonIdx[i];
        uint2 photonIdx2D = uint2(photonIdx / kInfoTexHeight, photonIdx % kInfoTexHeight);
        float3 photonFlux, photonDir;
        if (isCaustic)
        {
            photonFlux = gCausticFlux[photonIdx2D].xyz;
            photonDir = gCausticDir[photonIdx2D].xyz;
        }
        else
        {
            photonFlux = gGlobalFlux[photonIdx2D].xyz;
            photonDir = gGlobalDir[photonIdx2D].xyz;
        }
        const float3 wo = -photonDir;
        float3 f_r = bsdf.eval(sd, wo, rayData.sg);
       
        radiance += f_r * photonFlux;
    }

    //Weight output radiance with number of photons for this pixel
    return radiance * (float(rayData.counter) / float(maxIdx));
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    float4 thpMatID = gThpMatID[launchIndex];
    float3 viewW = gViewWorld[launchIndex].xyz;

    //prepare payload
    RayData rayData;
    rayData.counter = 0;
    rayData.sg = SampleGenerator(launchIndex, gFrameCount);
    
    const HitInfo hit = HitInfo(gVBuffer[launchIndex]);
    bool valid = hit.isValid(); //Check if the ray is valid (value over 0.1 in w coordinate of position)

    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -viewW, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    
    RayDesc ray;
    ray.Origin = v.posW;
    ray.TMin = RAY_TMIN;
    ray.TMax = RAY_TMAX;
    ray.Direction = viewW.xyz; //we take the view dir as direction
    
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    float3 radiance = float3(0);
    
    //It is faster to trace two times in the different instance mask because of divergence
    if (gCollectCausticPhotons && valid)
    {
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float3 radiancePhotons = photonContribution(sd, bsdf, rayData, true);
        float w = 1 / (M_PI * gCausticRadius * gCausticRadius); //make this a constant
        radiance += w * radiancePhotons;
        rayData.counter = 0;
    }
        
    if (gCollectGlobalPhotons && valid)
    {
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float3 radiancePhotons = photonContribution(sd, bsdf, rayData, false);
        float w = 1 / (M_PI * gGlobalRadius * gGlobalRadius); //make this a constant
        radiance += w * radiancePhotons;
    }
        
    radiance *= thpMatID.xyz;

    float3 pixEmission = gEmissive[launchIndex].xyz;
    radiance += pixEmission * thpMatID.xyz;
    
    //Accumulate the image (Put in accumulate pass ? )
    if (gFrameCount > 0 )
    {
        float3 last = gPhotonImage[launchIndex].xyz;
        float frameCountF = float(gFrameCount);
        last *= frameCountF;
        radiance += last;
        radiance /= frameCountF + 1.0;
    }
    
    gPhotonImage[launchIndex] = float4(radiance, 1);
}

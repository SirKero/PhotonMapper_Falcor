#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
//import Experimental.Scene.Material.MaterialHelpers;
import Rendering.Lights.LightHelpers;


cbuffer CB
{
    uint gFrameCount;       // Frame count since scene was loaded.
    float gCausticRadius;   // Radius for the caustic photons
    float gGlobalRadius;    // Radius for the global photons
    bool gNoColorOutput;    // Skips light calculation if activated and outputs 1 on all channels
    float gEmissiveScale;   // Scale for the emissive part
}

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
    float radius;
    float3 flux;
    float pad2;
};

 //Internal Buffer Structs

RWStructuredBuffer<PhotonInfo> gCaustic;
RWStructuredBuffer<PhotonInfo> gGlobal;
RWStructuredBuffer<AABB> gCausticAABB;
RWStructuredBuffer<AABB> gGlobalAABB;

// Static configuration based on defines set from the host.
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

static const bool kCollectGlobalPhotons = COLLECT_GLOBAL_PHOTONS;
static const bool kCollectCausticPhotons = COLLECT_CAUSTIC_PHOTONS;

static const float kRayTMin = RAY_TMIN;
static const float kRayTMax = RAY_TMAX;

/** Payload for ray (32B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    uint pad;                       ///< free space.
    PackedHitInfo packedHitInfo;    ///< Hit info from vBuffer; Up to 16B
  
    __init(){
        this.radiance = float3(0);
        this.pad = 0;
    }
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
    //debug white output
    if (gNoColorOutput)
    {
        rayData.radiance = float3(1);
        return;
    }

    const uint2 launchIndex = DispatchRaysIndex().xy;
    const uint primIndex = PrimitiveIndex();
    
    //get caustic or global photon
    PhotonInfo photon;
     //Instance 0 is always the caustic buffer
    if (InstanceIndex() == 0)
    {
        photon = gCaustic[primIndex];
    }
    else
    {
        photon = gGlobal[primIndex];
    }

    //get hit
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    let lod = ExplicitLodTextureSampler(0.f);
    //World Direction is set to the viewDir we get from the vBuffer
    ShadingData sd = loadShadingData(hit, WorldRayDirection(), lod);
        
    let bsdf = gScene.materials.getBSDF(sd, lod);
    
    float3 woLocal = float3(dot(-photon.dir, sd.T), dot(-photon.dir, sd.B), dot(-photon.dir, sd.N));
    float3 wiLocal = sd.toLocal(sd.V);

     // Get BSDF properties.
    let bsdfProperties = bsdf.getProperties(sd);
        
    float3 f_r = float3(1);
    f_r = bsdf.eval(sd, -photon.dir);
       
    rayData.radiance += f_r * photon.flux;
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
        ReportHit(RAY_TMIN, 0, attribs);
    }
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    float4 thpMatID = gThpMatID[launchIndex];

    //prepare payload
    RayData rayData = RayData();
    rayData.packedHitInfo = gVBuffer[launchIndex];
    
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    bool valid = hit.isValid(); //Check if the ray is valid (value over 0.1 in w coordinate of position)

    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    
    RayDesc ray;
    ray.Origin = v.posW;
    ray.TMin = RAY_TMIN;
    ray.TMax = RAY_TMAX;
    ray.Direction = gViewWorld[launchIndex].xyz;    //we take the view dir as direction
    
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    float3 radiance = float3(0);
    
    //It is faster to trace two times in the different instance mask becaus of divergence
    if (kCollectCausticPhotons && valid)
    {
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gCausticRadius * gCausticRadius); //make this a constant
        radiance += w * rayData.radiance;
        rayData.radiance = 0.0;
    }
        
    if (kCollectGlobalPhotons && valid)
    {
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gGlobalRadius * gGlobalRadius); //make this a constant
        radiance += w * rayData.radiance;
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

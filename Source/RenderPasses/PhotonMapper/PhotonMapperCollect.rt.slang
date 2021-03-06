#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Material.ShadingUtils;
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
    float4 dir;
    float4 flux;
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
static const bool kUsePhotonFaceNormal = PHOTON_FACE_NORMAL;

static const float kRayTMin = RAY_TMIN;
static const float kRayTMax = RAY_TMAX;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance;                ///< Accumulated outgoing radiance from path.
    uint pad;                       ///< free space.
    PackedHitInfo packedHitInfo;    ///< Hit info from vBuffer; Up to 16B

    SampleGenerator sg;
  
    __init(){
        this.radiance = float3(0);
        this.pad = 0;
    }
};

struct SphereAttribs
{
    float2 pad;
};

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
    adjustShadingNormal(sd, v);
    
    return sd;
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
    const uint2 primIndex2D = uint2(primIndex / kInfoTexHeight, primIndex % kInfoTexHeight);
    //get caustic or global photon
    PhotonInfo photon;
     //Instance 0 is always the caustic buffer
    if (InstanceIndex() == 0)
    {
        photon.flux = gCausticFlux[primIndex2D];
        photon.dir = gCausticDir[primIndex2D];
    }
    else
    {
        photon.flux = gGlobalFlux[primIndex2D];
        photon.dir = gGlobalDir[primIndex2D];
    }

    //get hit
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    let lod = ExplicitLodTextureSampler(0.f);
    //World Direction is set to the viewDir we get from the vBuffer
    ShadingData sd = loadShadingData(hit, WorldRayDirection(), lod);

    //Do face normal test if enabled
    if(kUsePhotonFaceNormal){
        //Sperical to cartesian
        float sinTheta = sin(photon.flux.w);
        float3 photonFaceN = float3(cos(photon.dir.w) * sinTheta, cos(photon.flux.w), sin(photon.dir.w) * sinTheta);
        photonFaceN = normalize(photonFaceN);
        float3 faceN = dot(-WorldRayDirection(), sd.faceN) > 0 ? sd.faceN : -sd.faceN;
        //Dot product has to be negative (View dir points to surface)
        if(dot(faceN, photonFaceN) < 0.9f)
            return;
    }

    
    let bsdf = gScene.materials.getBSDF(sd, lod);
            
    float3 f_r = bsdf.eval(sd, -photon.dir.xyz, rayData.sg);
       
    rayData.radiance += f_r * photon.flux.xyz;
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


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    float4 thpMatID = gThpMatID[launchIndex];

    //prepare payload
    RayData rayData = RayData();
    rayData.packedHitInfo = gVBuffer[launchIndex];
    rayData.sg = SampleGenerator(launchIndex, gFrameCount);
    
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
    if (gCollectCausticPhotons && valid)
    {
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gCausticRadius * gCausticRadius); //make this a constant
        radiance += w * rayData.radiance;
        rayData.radiance = 0.0;
    }
        
    if (gCollectGlobalPhotons && valid)
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

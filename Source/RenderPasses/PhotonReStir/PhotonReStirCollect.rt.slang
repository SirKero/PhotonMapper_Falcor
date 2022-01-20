
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Experimental.Scene.Material.StandardMaterial;
import Experimental.Scene.Material.MaterialHelpers;
import Experimental.Scene.Lights.LightHelpers;


cbuffer CB
{
    uint gFrameCount;       // Frame count since scene was loaded.
    float gCausticRadius;   // Radius for the caustic photons
    float gGlobalRadius;    // Radius for the global photons
    bool gNoColorOutput;    // Skips light calculation if activated and outputs 1 on all channels
    float gEmissiveScale;   // Scale for the emissive part
}

static struct Data
{
    // Materials
    StandardMaterial standardMaterial;
} gData;

// Inputs
Texture2D<float4> gWorldPosition;
Texture2D<float4> gWorldNormal;
Texture2D<float4> gWorldTangent;
Texture2D<float2> gTextureCoordinate;
Texture2D<float4> gDiffuseOpacity;
Texture2D<float4> gSpecularRoughness;
Texture2D<float4> gEmissive;
Texture2D<float4> gMaterialExtra;
Texture2D<float4> gViewWorld;
Texture2D<float4> gFaceNormal;


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
static const float kRayTMax = FLT_MAX;

static const bool kCollectGlobalPhotons = COLLECT_GLOBAL_PHOTONS;
static const bool kCollectCausticPhotons = COLLECT_CAUSTIC_PHOTONS;

/** Payload for ray (128B).
*/
struct RayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    bool terminated; ///< Set to true when path is terminated.
    float3 wNormal;
    float texU;
    float3 wView;
    float texV;
    float4 wTangent;
    float4 diffuseOpacity;
    float4 specularRoughness;
    float4 emissive;
    float4 extraParams;
  

    static RayData create()
    {
        RayData r;
        r.radiance = float3(0);
        r.terminated = false;
        r.wNormal = float3(0);
        r.texU = 0.0;
        r.wView = float3(0);
        r.texV = 0.0;
        r.diffuseOpacity = float4(0);
        r.specularRoughness = float4(0);
        r.emissive = float4(0);
        r.extraParams = float4(0);
        r.wTangent = float4(0);

        return r;
    }
};

struct SphereAttribs
{
    float2 pad;
};

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.terminated = true;
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

    const uint primIndex = PrimitiveIndex();
    //get caustic or global photon
    PhotonInfo photon;
    float radius = 0;
     //Instance 0 is always the caustic buffer
    if (InstanceIndex() == 0)
    {
        photon = gCaustic[primIndex];
        radius = gCausticRadius;
    }
    else
    {
        photon = gGlobal[primIndex];
        radius = gGlobalRadius;
    }

    //create shading data
    MaterialParams matPara;
    matPara.diffuseOpacity = rayData.diffuseOpacity;
    matPara.specularRoughness = rayData.specularRoughness;
    matPara.emissive = rayData.emissive;
    matPara.extraParams = rayData.extraParams;
    float3 faceNormal = gFaceNormal[DispatchRaysIndex().xy].xyz;    //TODO: encode that in the struct

    GeometryParams geoPara = prepareGeometryParams(ObjectRayOrigin() /*wPos*/, rayData.wView, rayData.wNormal, rayData.wTangent, faceNormal, float2(rayData.texU, rayData.texV));

    ShadingData sd = prepareShadingData(geoPara, matPara);
    FalcorBSDF bsdf;
    bsdf.setup(sd);
    float3 wiLocal = sd.toLocal(sd.V);
    float3 woLocal = float3(dot(-photon.dir, sd.T), dot(-photon.dir, sd.B), dot(-photon.dir, sd.N));

    float3 f_r = bsdf.eval(wiLocal, woLocal);
    float w = 1 / (radius * radius);
    
    rayData.radiance += f_r * photon.flux * w;
}

//Checks if the ray start point is inside the sphere. 0 is returned if it is not in sphere and 1 if it is
float hitSphere(const float3 center, const float radius, const float3 p)
{
    float check = 0.0;
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        check = 0.01; //put check as a small constant value so we can shoot little rays
  
    return check;
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
        
    float tHit = hitSphere(photonAABB.center(), radius, origin);

    SphereAttribs attribs;
    attribs.pad = float2(0);
    
    if (tHit > 0.0)
    {
        ReportHit(0.005, 0, attribs);
    }
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    float4 wPos = gWorldPosition[launchIndex];
    float2 texCoord = gTextureCoordinate[launchIndex];
    //prepare payload
    RayData rayData = RayData.create();
    rayData.wNormal = gWorldNormal[launchIndex].xyz;
    rayData.texU = texCoord.x;
    rayData.wView = gViewWorld[launchIndex].xyz;
    rayData.texV = texCoord.y;
    rayData.wTangent = gWorldTangent[launchIndex];
    rayData.diffuseOpacity = gDiffuseOpacity[launchIndex];
    rayData.specularRoughness = gSpecularRoughness[launchIndex];
    rayData.emissive = gEmissive[launchIndex];
    rayData.extraParams = gMaterialExtra[launchIndex];
    //rayData.wFaceNormal = gFaceNormal[launchIndex];
    
    RayDesc ray;
    ray.Origin = wPos.xyz;
    ray.TMin = 0.001;
    ray.TMax = 0.01;
    ray.Direction = rayData.wNormal;
    
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;

    //It is faster to trace two times in the different instance mask becaus of divergence
    if (kCollectCausticPhotons)
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    if(kCollectGlobalPhotons)
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);

    float w = 1 / M_PI;

    float3 radiance = w * rayData.radiance;

    float3 pixEmission = gEmissive[launchIndex].xyz *0.05;
    radiance += pixEmission;
    
    //Accumulate the image
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

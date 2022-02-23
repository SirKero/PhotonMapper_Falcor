#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
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
Texture2D<float4> gWorldPosition;
Texture2D<float4> gWorldNormal;
Texture2D<float4> gWorldTangent;
Texture2D<float2> gTextureCoordinate;
Texture2D<float4> gViewWorld;
Texture2D<float4> gFaceNormal;
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
static const float kRayTMax = FLT_MAX;

static const bool kCollectGlobalPhotons = COLLECT_GLOBAL_PHOTONS;
static const bool kCollectCausticPhotons = COLLECT_CAUSTIC_PHOTONS;

/** Payload for ray (128B).
*/
struct RayData
{
    float3 radiance;    ///< Accumulated outgoing radiance from path.
    bool terminated;    ///< Set to true when path is terminated.
    float3 wNormal;      ///< World normal
    float texU;         ///< U of texture coordinate 
    float3 wView;       ///< World View
    float texV;         ///< V of texture coordinate 
    float4 wTangent;    ///< Tangent, w component is the direction for the bitangent (either -1 or +1)
    float3 wFaceNormal; ///< Face Normal
    uint matID;         ///< MaterialID
  

    __init(){
        this.radiance = float3(0);
        this.terminated = false;
        this.wNormal = float3(0);
        this.texU = 0.0;
        this.wView = float3(0);
        this.texV = 0.0;
        this.wTangent = float4(0);
        this.wNormal = float3(0);
        this.matID = 0;
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

    //create a Vertex Data object
    VertexData v;
    v.posW = ObjectRayOrigin().xyz;
    v.normalW = rayData.wNormal;
    v.faceNormalW = rayData.wFaceNormal;
    v.tangentW = rayData.wTangent;
    v.texC = float2(rayData.texU, rayData.texV);
    v.coneTexLODValue = 0.0;

    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, rayData.matID, rayData.wView, lod);
        
    let bsdf = gScene.materials.getBSDF(sd, lod);
    
    float3 woLocal = float3(dot(-photon.dir, sd.T), dot(-photon.dir, sd.B), dot(-photon.dir, sd.N));
    float3 wiLocal = sd.toLocal(sd.V);

     // Get BSDF properties.
    let bsdfProperties = bsdf.getProperties(sd);
        
    float3 f_r = float3(1);
    f_r = bsdf.eval(sd, -photon.dir);
        
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
        ReportHit(0.00005, 0, attribs);
    }
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
    
    float4 wPos = gWorldPosition[launchIndex];
    float2 texCoord = gTextureCoordinate[launchIndex];
    float4 thpMatID = gThpMatID[launchIndex];

    //prepare payload
    RayData rayData = RayData();
    rayData.texU = texCoord.x;
    rayData.wView = gViewWorld[launchIndex].xyz;
    rayData.texV = texCoord.y;
    rayData.wTangent = gWorldTangent[launchIndex];
    rayData.matID = asuint(thpMatID.w); 
    rayData.wNormal = gWorldNormal[launchIndex].xyz;
    rayData.wFaceNormal = gFaceNormal[launchIndex].xyz;

    bool valid = !(wPos.w < 0.1);   //Check if the ray is valid (value over 0.1 in w coordinate of position)
    
    RayDesc ray;
    ray.Origin = wPos.xyz;
    ray.TMin = 0.00001;
    ray.TMax = 0.0001;
    ray.Direction = float3(0, 1, 0);
    
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;

    //It is faster to trace two times in the different instance mask becaus of divergence
    if (kCollectCausticPhotons && valid)
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    
    if (kCollectGlobalPhotons && valid)
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
    
    float w = 1 / M_PI;     //make this a constant

    float3 radiance = float3(0);
        
    radiance = valid ? w * rayData.radiance * thpMatID.xyz : float3(0.0);

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


#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Experimental.Scene.Material.StandardMaterial;
import Experimental.Scene.Material.MaterialHelpers;
import Experimental.Scene.Lights.LightHelpers;


cbuffer CB
{
    uint        gFrameCount;        // Frame count since scene was loaded.
    float3      gDirLightWorldPos;  // world pos for a dir light if given
    float       gCausticRadius;     // Radius for the caustic photons
    float       gGlobalRadius;      // Radius for the global photons
    float gRussianRoulette;         // Probabilty that an global photon is saved
}

static struct Data
{
    // Materials
    StandardMaterial standardMaterial;
} gData;

// Inputs

// Outputs
RWTexture2D<float4> gPhotonImage;

//Internal Buffer Structs

struct PhotonInfo {
        float3 pos;
        float radius;
        float3 flux;
        float pad2;
};

 //Internal Buffer Structs

RWStructuredBuffer<PhotonInfo> gCaustic;
RWStructuredBuffer<PhotonInfo> gGlobal;
RWStructuredBuffer<AABB> gCausticAABB;
RWStructuredBuffer<AABB> gGlobalAABB;

struct PhotonCounter
{
    uint caustic;
    uint global;
};
RWStructuredBuffer<PhotonCounter> gPhotonCounter;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;
static const uint kMaxPhotonIndex = MAX_PHOTON_INDEX;

/** Payload for scatter ray (80B).
*/
struct ScatterRayData
{
    float3  radiance;       ///< Accumulated outgoing radiance from path.
    bool    terminated;     ///< Set to true when path is terminated.
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint    pathLength;     ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3  origin;         ///< Next path segment origin.
    bool    specularRef;    ///< Set to true if the ray is reflected/transmitted specular
    float3  direction;      ///< Next path segment direction.
    uint    _pad1;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static ScatterRayData create(SampleGenerator sg)
    {
        ScatterRayData d;
        d.terminated = false;
        d.specularRef = false;
        d.pathLength = 0;
        d.radiance = float3(0, 0, 0);
        d.thp = float3(1, 1, 1);
        d.origin = float3(0, 0, 0);
        d.direction = float3(0, 0, 0);
        d.sg = sg;
        return d;
    }
};

void calcHemispehreDir(in LightData light,in SampleGenerator sg, inout float3 newDir)
{
    //get random pos in hemisphere
    float2 rnd = sampleNext2D(sg);  //random numbers for z and phi
    float r = sqrt(max(0.0, 1. - rnd.x * rnd.x));
    float phi = rnd.y * 2 * M_PI;
    float3 rndDirL = float3(r * cos(phi), r * sin(phi), rnd.x);

    //transform from local space -> random dir vector in world space
    float3 tangent, bitangent;
    if (abs(light.dirW.x) < 0.99)
        tangent = cross(light.dirW, float3(1., 0., 0.));
    else
        tangent = cross(light.dirW, float3(0., 1., 0.));
    //tangent = normalize(tangent);
    bitangent = cross(tangent, light.dirW);

    newDir = rndDirL.x * tangent + rndDirL.y * bitangent + rndDirL.z * light.dirW;
}

AABB calcPhotonAABB(in PhotonInfo photon)
{
    AABB aabb = AABB.create(photon.pos - photon.radius, photon.pos + photon.radius);
    return aabb;
}

[shader("miss")]
void miss(inout ScatterRayData rayData : SV_RayPayload)
{
    rayData.terminated = true;

    //TODO: Add enviroment map color if ray misses scene 
}

[shader("closesthit")]
void closestHit(inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -WorldRayDirection(), 0.f);

    //compute ray origin for the new ray
    float3 rayOrigin = sd.computeNewRayOrigin();

    float pdf = 0.f;
    uint lobe = 0;
    float3 wiLocal = sd.toLocal(sd.V);
    float3 woLocal = { }, weight = { };

    FalcorBSDF bsdf;
    bsdf.setup(sd);
    bool valid = bsdf.sample(wiLocal, woLocal, pdf, weight, lobe, rayData.sg);

    float3 res = bsdf.eval(wiLocal, woLocal);   //TODO: Check if order is correct


    //set ray data
    rayData.origin = rayOrigin;
    rayData.direction = sd.fromLocal(woLocal);
    rayData.thp = valid ? res / pdf : float3(0);
    rayData.specularRef = (lobe & (uint)LobeType::Specular) > 0;    //was reflected specular or diffuse
    //if throughput is 0, return
    if(!any(rayData.thp > 0.f))
        rayData.terminated = true;
    
    rayData.pathLength++;
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
     
    SampleGenerator sg = SampleGenerator.create(launchIndex, gFrameCount);

    LightCollection lc = gScene.lightCollection;
       
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return;

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.
    
    LightData currentLight = gScene.getLight(lightIndex);

    //set a pos for dir lights
    if (currentLight.type == 1)
    {
        currentLight.posW = gDirLightWorldPos;
    }
    if (currentLight.type > 1)
        return;

    RayDesc ray;
    calcHemispehreDir(currentLight, sg, ray.Direction);

    //create photon
    PhotonInfo photon;
    photon.pos = float3(0, 0, 0);
    photon.radius = 0.f;
    photon.flux = float3(0, 0, 0);
    photon.pad2 = 0.f;
    
    //light flux
    float3 lightFlux = currentLight.intensity * 2 * M_PI * invPdf;
    photon.flux = lightFlux / float3(launchDim.x * launchDim.y);

    //ray tracing vars
    ray.Origin = currentLight.posW;
    ray.TMin = 0.01f;
    ray.TMax = 1000.f;
    uint rayFlags = 0;

    bool wasReflectedSpecular = false;
    bool reflectedDiffuse = false;
    
    // Prepare ray payload.
    ScatterRayData rayData = ScatterRayData.create(sg);
    
    //recursion where the photons are shot
    for (uint i = 0; i < kMaxBounces && !rayData.terminated; i++)
    {
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        photon.pos = rayData.origin;
        reflectedDiffuse = !rayData.specularRef;
        //save photon
        //TODO: Add max for photon insertion
        bool roulette = sampleNext1D(sg) <= gRussianRoulette;
        if (reflectedDiffuse)
        {
            //caustic photon
            if (wasReflectedSpecular)
            {
                photon.radius = gCausticRadius;
                uint photonIndex = 0;
                InterlockedAdd(gPhotonCounter[0].caustic, 1u, photonIndex);
                photonIndex = max(photonIndex, kMaxPhotonIndex);
                AABB photonAABB = calcPhotonAABB(photon);
                gCaustic[photonIndex] = photon;           //this causes error for some reason    
                gCausticAABB[photonIndex] = photonAABB;
            }
            //Global photon
            else if(roulette)
            {
                photon.flux = photon.flux / gRussianRoulette;
                photon.radius = gGlobalRadius;
                uint photonIndex = 0;
                InterlockedAdd(gPhotonCounter[0].global, 1u, photonIndex);
                photonIndex = max(photonIndex, kMaxPhotonIndex);
                AABB photonAABB = calcPhotonAABB(photon);
                gGlobal[photonIndex] = photon;
                gGlobalAABB[photonIndex] = photonAABB;
            }
        }
        
        //Update photon energy
        float avgThroughput = (rayData.thp.x + rayData.thp.y + rayData.thp.z) / 3;

        float rnd = sampleNext1D(sg);
        if (avgThroughput < rnd)
        {
            break;      //Photon is absorbed
        }
        else
        {
            photon.flux *= rayData.thp / avgThroughput;
        }

        wasReflectedSpecular = !reflectedDiffuse;
        
        //update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
    }


    gPhotonImage[launchIndex] = float4(float3(rayData.pathLength) / kMaxBounces, 1);
    
}

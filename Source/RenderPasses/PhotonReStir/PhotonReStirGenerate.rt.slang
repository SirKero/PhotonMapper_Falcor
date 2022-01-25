
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
    float       gRussianRoulette;   // Probabilty that an global photon is saved
    float       gEmissiveScale;   //scalar for the light intenity
    uint        gPRNGDimension;     // First available PRNG dimension.
}

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


// Outputs
RWTexture2D<float4> gPhotonImage;

// Outputs
RWTexture2D<float4> gPhotonTestImage;

//Internal Buffer Structs

struct PhotonInfo {
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

StructuredBuffer<uint> gRndSeedBuffer;

struct PhotonCounter
{
    uint caustic;
    uint global;
};
RWStructuredBuffer<PhotonCounter> gPhotonCounter;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxRecursion = MAX_RECURSION;
static const float kMaxUintF = MAX_UINT32F;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;
static const uint kMaxPhotonIndex = MAX_PHOTON_INDEX;

static const float Inv2Pi = 0.15915494309189533577;
static const float Inv4Pi = 0.07957747154594766788;


/** Payload for scatter ray (80B).
*/
struct ScatterRayData
{
    float3  radiance;       ///< Accumulated outgoing radiance from path.
    bool    terminated;     ///< Set to true when path is terminated.
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint    pathLength;     ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3  origin;         ///< Next path segment origin.
    uint    lobeType;       ///< Mask for the type of reflection
    float3  direction;      ///< Next path segment direction.
    uint    _pad1;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static ScatterRayData create()
    {
        ScatterRayData d;
        d.terminated = false;
        d.lobeType = 0;
        d.pathLength = 0;
        d.radiance = float3(0, 0, 0);
        d.thp = float3(1, 1, 1);
        d.origin = float3(0, 0, 0);
        d.direction = float3(0, 0, 0);
        return d;
    }
};

//transforms direction from local to world space
void fromLocalToWorld(in float3 lightDirW, inout float3 dir)
{
    //transform from local space -> random dir vector in world space
    float3 tangent, bitangent;
    if (abs(lightDirW.x) < 0.99)
        tangent = cross(lightDirW, float3(1., 0., 0.));
    else
        tangent = cross(lightDirW, float3(0., 1., 0.));
    //tangent = normalize(tangent);
    bitangent = cross(tangent, lightDirW);

    dir = dir.x * tangent + dir.y * bitangent + dir.z * lightDirW;
}

//Samples a random direction in a hemisphere or nornmal sphere
void calcLightDirection(in float3 lightDirW,in SampleGenerator sg, inout float3 newDir, inout float lightPDF , bool hemisphereSample = true)
{
    //get random pos in hemisphere
    float2 rnd = sampleNext2D(sg);  //random numbers for z and phi
    if(!hemisphereSample)
        rnd.x = 1.0 - 2.0 * rnd.x;
    float r = sqrt(max(0.0, 1. - rnd.x * rnd.x));
    float phi = rnd.y * 2 * M_PI;
    newDir = float3(r * cos(phi), r * sin(phi), rnd.x);

    fromLocalToWorld(lightDirW, newDir);
    lightPDF = hemisphereSample ? Inv2Pi : Inv4Pi;
}

AABB calcPhotonAABB(in float3 center, in float radius)
{
    AABB aabb = AABB.create(center - radius, center + radius);
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

    float pdf = 0.f;
    uint lobe = 0;
    float3 wiLocal = sd.toLocal(sd.V);
    float3 woLocal = { }, weight = { };

    FalcorBSDF bsdf;
    bsdf.setup(sd);
    bool valid = bsdf.sample(wiLocal, woLocal, pdf, weight, lobe, rayData.sg);

    float3 res = bsdf.eval(wiLocal, woLocal);   //TODO: Check if order is correct

    bool transmission = (lobe & (uint) LobeType::Transmission) > 0;
    //compute ray origin for the new ray
    float3 rayOrigin = sd.computeNewRayOrigin(!transmission);   //false is for transmissions
    
    //set ray data
    rayData.origin = rayOrigin;
    rayData.direction = sd.fromLocal(woLocal);
    rayData.thp = valid ? res / pdf : float3(0);
    rayData.lobeType = lobe;                         //save lobe type
    rayData.thp = min(max(rayData.thp, float3(0)), float3(1.0));
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

    //random seed
    uint launchIndex1D = launchIndex.x + launchIndex.y * launchDim.x;
    uint seed = gRndSeedBuffer[launchIndex1D];
    
     // Prepare ray payload.
    ScatterRayData rayData = ScatterRayData.create();
    rayData.sg = SampleGenerator.create(launchIndex, seed + gFrameCount);

    // Advance the generator to the first available dimension.
    // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
    for (uint i = 0; i < gPRNGDimension; i++)
        sampleNext1D(rayData.sg);
    
    LightCollection lc = gScene.lightCollection;
       
    const uint analyticLightCount = kUseAnalyticLights ? gScene.getLightCount() : 0;
    const uint emissiveLightCount = kUseEmissiveLights ? lc.getActiveTriangleCount() : 0;
    const uint lightCount = analyticLightCount + emissiveLightCount;
    
    if (lightCount == 0)        //If that case happens we have a problem 
        return;
    
    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(rayData.sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

    float3 lightPos = float3(0);
    float3 lightDir = float3(0, 1, 0);
    float3 lightIntensity = float3(0);

    uint type = 0;  //0 == Point, 1 == Area

    //Point or Dir light
    if (lightIndex < analyticLightCount)
    {
        LightData currentLight = gScene.getLight(lightIndex);

    //we only support point and dir lights
        if (currentLight.type != uint(LightType::Point))
            return;

        lightPos = currentLight.posW;
        lightDir = currentLight.dirW;
        lightIntensity = currentLight.intensity;
    }
    //emissive triangle light
    else
    {
        const uint activeTriIndex = lightIndex - analyticLightCount;
        const uint triIndex = lc.activeTriangles[activeTriIndex];
        EmissiveTriangle emiTri = lc.getTriangle(triIndex); //get the random triangle
        //random baycentric coordinates
        float2 RS = sampleNext2D(rayData.sg);
        if (RS.x + RS.y >= 1.0)            //make sure that it stays inside the triangle
            RS = 1.0 - RS;
        float3 bay = float3(RS.x, RS.y, 1.0 - (RS.x + RS.y));
        lightPos = emiTri.getPosition(bay);
        lightDir = emiTri.normal;
        lightIntensity = lc.getAverageRadiance(triIndex);
        type = 1;
    }

   
    
    RayDesc ray;
    float lightDirPDF = 0.0;
    calcLightDirection(lightDir, rayData.sg, ray.Direction, lightDirPDF ,type == 0 ? false : true);

    //create photon
    float3 photonPos = float3(0, 0, 0);
    PhotonInfo photon;
    photon.dir = float3(0, 0, 0);
    photon.radius = 0.f;
    photon.flux = float3(0, 0, 0);
    photon.pad2 = 0.f;
    
    //light flux
    float3 lightFlux = lightIntensity * lightDirPDF * invPdf * gEmissiveScale;
    photon.flux = lightFlux / float3(launchDim.x * launchDim.y);

    //ray tracing vars
    ray.Origin = lightPos + 0.01 * ray.Direction;
    ray.TMin = 0.01f;
    ray.TMax = 1000.f;
    uint rayFlags = 0;

    bool wasReflectedSpecular = false;
    bool reflectedDiffuse = false;
    
   
    
    //recursion where the photons are shot
    for (uint i = 0; i < kMaxRecursion && !rayData.terminated; i++)
    {
        
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        if(rayData.terminated)
            break;
        
        photonPos = rayData.origin;
        photon.dir = ray.Direction;
        reflectedDiffuse = ((uint) LobeType::DiffuseReflection & rayData.lobeType) > 0;

        //save photon
        float rndRoulette = sampleNext1D(rayData.sg);
        bool roulette = rndRoulette <= gRussianRoulette;

        
        if (reflectedDiffuse)
        {
            //caustic photon
            if (wasReflectedSpecular)
            {
                photon.radius = gCausticRadius;
                uint photonIndex = 0;
                InterlockedAdd(gPhotonCounter[0].caustic, 1u, photonIndex);
                photonIndex = min(photonIndex, kMaxPhotonIndex);
                AABB photonAABB = calcPhotonAABB(photonPos, gCausticRadius);
                gCaustic[photonIndex] = photon; //this causes error for some reason    
                gCausticAABB[photonIndex] = photonAABB;
            }
            //Global photon
            else if(roulette)
            {
                photon.flux = photon.flux / gRussianRoulette;
                photon.radius = gGlobalRadius;
                uint photonIndex = 0;
                InterlockedAdd(gPhotonCounter[0].global, 1u, photonIndex);
                photonIndex = min(photonIndex, kMaxPhotonIndex);
                AABB photonAABB = calcPhotonAABB(photonPos, gGlobalRadius);
                gGlobal[photonIndex] = photon;
                gGlobalAABB[photonIndex] = photonAABB;
            }
        }
        

         //Update photon energy
        float avgThroughput = max((rayData.thp.x + rayData.thp.y + rayData.thp.z) / 3, 0.0);

        float rnd = sampleNext1D(rayData.sg);
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
    
}

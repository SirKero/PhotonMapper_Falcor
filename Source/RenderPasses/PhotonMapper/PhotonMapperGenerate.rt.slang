#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Scene.Material.ShadingUtils;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;


cbuffer CB
{
    uint        gFrameCount;        // Frame count since scene was loaded.
    float       gCausticRadius;     // Radius for the caustic photons
    float       gGlobalRadius;      // Radius for the global photons
    uint        gPRNGDimension;     // First available PRNG dimension.
}

// Inputs
Texture2D<int> gLightSample;
//Internal Buffer Structs

struct PhotonInfo {
        float3 dir;
        float faceNTheta;
        float3 flux;
        float faceNPhi;
};

 //Internal Buffer Structs

RWTexture2D<float4> gCausticFlux;
RWTexture2D<float4> gCausticDir;
RWTexture2D<float4> gGlobalFlux;
RWTexture2D<float4> gGlobalDir;
RWStructuredBuffer<AABB> gCausticAABB;
RWStructuredBuffer<AABB> gGlobalAABB;

Texture2D<uint> gRndSeedBuffer;

struct PhotonCounter
{
    uint caustic;
    uint global;
};
RWStructuredBuffer<PhotonCounter> gPhotonCounter;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxRecursion = MAX_RECURSION;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;
static const uint kMaxPhotonIndexGLB = MAX_PHOTON_INDEX_GLOBAL;
static const uint kMaxPhotonIndexCAU = MAX_PHOTON_INDEX_CAUSTIC;
static const float kRussianRoulette = RUSSIAN_ROULETTE;             // Probabilty that an global photon is saved
static const float kEmissiveScale = EMISSIVE_SCALE;                 //scalar for the light intenity
static const float kSpecRoughCutoff = SPECULAR_ROUGNESS_CUTOFF;     //If roughness value is over this, interpret the material as Diffuse
static const bool kUseAlphaTest = USE_ALPHA_TEST;                   //Activate for alpha test
static const bool kAdjustShadingNormals = ADJUST_SHADING_NORMALS;   //Adjust the shading normals
static const float kAnalyticInvPdf = ANALYTIC_INV_PDF;              //Inverse analytic pdf 
static const float kEmissiveInvPdf = EMISSIVE_INV_PDF;              //Inverse emissive pdf
static const uint kInfoTexHeight = INFO_TEXTURE_HEIGHT;

static const float k_2Pi = 6.28318530717958647692;
static const float k_4Pi = 12.5663706143591729538;
static const float Inv2Pi = 0.15915494309189533577;
static const float Inv4Pi = 0.07957747154594766788;


/** Payload for scatter ray (64B).
*/
struct RayData
{
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    float    cosTheta;     ///< Cos Theta
    float3  origin;         ///< Next path segment origin.
    bool terminated; ///< Set to true when path is terminated.
    float3  direction;      ///< Next path segment direction.
    bool    diffuseHit;     ///< saves if the his is diffuse

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static RayData create()
    {
        RayData d;
        d.terminated = false;
        d.cosTheta = 1.f;
        d.thp = float3(1, 1, 1);
        d.origin = float3(0, 0, 0);
        d.direction = float3(0, 0, 0);
        return d;
    }
};

//get the area of a triangle from the vectors a and b. 
float triangleArea(float3 a, float3 b)
{
    float2 len = float2(length(a), length(b));
    float cosT = dot(a / len.x, b / len.y);
    float sinT = sqrt(1 - cosT * cosT);

    return 0.5 * len.x * len.y * sinT;
}

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

/** *Samples a random direction in a hemisphere or nornmal sphere
    * type for the different light types. 0 =Point ; 1 = Area ; 2 = Spot
*/
void calcLightDirection(in float3 lightDirW, float2 rnd, inout float3 newDir, inout float lightPDF , uint type , float cosThetaMax = M_PI)
{
    //theta and pdf for the different light types
    switch (type)
    {
        //Point
        case 0:
            newDir = sample_sphere(rnd);
            lightPDF = k_4Pi;
            break;
        //Area
        case 1:
            newDir = sample_cosine_hemisphere_polar(rnd, lightPDF);
            break;
        //Spot
        case 2:
            newDir = sample_cone(rnd, cosThetaMax);
            lightPDF = 1 / (k_2Pi * (1.0 - cosThetaMax));
    }
    
    fromLocalToWorld(lightDirW, newDir);
}

AABB calcPhotonAABB(in float3 center, in float radius)
{
    AABB aabb = AABB(center - radius, center + radius);
    return aabb;
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.terminated = true;

    //TODO: Add enviroment map color if ray misses scene 
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    // Evaluate Falcor's material parameters at the hit point.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -WorldRayDirection(), lod);

    //Adjust shading normals if desired
    if (kAdjustShadingNormals)
    {
        adjustShadingNormal(sd, v);
    }
    
    BSDFSample bsdfSample;
    let bsdf = gScene.materials.getBSDF(sd, lod);
    let bsdfProperties = bsdf.getProperties(sd);

    bool valid = bsdf.sample(sd, rayData.sg, bsdfSample, true /*ImportanceSampling*/);

    float3 thpStart = rayData.thp;
    
    bool transmission = bsdfSample.isLobe(LobeType::Transmission);
    float3 rayOrigin = sd.computeNewRayOrigin(!transmission); //false is for transmissions
    rayData.origin = rayOrigin;
    rayData.thp *= valid ? bsdfSample.weight : float3(0);
    rayData.direction = bsdfSample.wo;
    rayData.diffuseHit = bsdfSample.isLobe(LobeType::Diffuse) || (bsdfSample.isLobe(LobeType::Reflection) && (bsdfProperties.roughness > kSpecRoughCutoff));
    rayData.cosTheta = abs(dot(sd.N, rayData.direction));
    
    //if throughput is 0, return
    if (!valid || any(rayData.thp < 0))
        rayData.terminated = true;
}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (kUseAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    //random seed
    uint seed = gRndSeedBuffer[launchIndex];
    
     // Prepare ray payload.
    RayData rayData = RayData.create();
    rayData.sg = SampleGenerator(launchIndex, seed + gFrameCount);

    // Advance the generator to the first available dimension.
    // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
    for (uint i = 0; i < gPRNGDimension; i++)
        sampleNext1D(rayData.sg);
    
    LightCollection lc = gScene.lightCollection;

    
    //Get current light index and type. For emissive triangles only active ones where sampled
    int lightIndex = gLightSample[launchIndex];
    // 0 means invalid light index
    if (lightIndex == 0)
        return;
    bool analytic = lightIndex < 0;     //Negative values are analytic lights
    if (analytic)
        lightIndex *= -1;           //Swap sign if analytic    
    lightIndex -= 1;                //Change index from 1->N to 0->(N-1)

    float invPdf = kAnalyticInvPdf;             //Set to analytic pdf by default. If Emissive it is set later
    float3 lightPos = float3(0);
    float3 lightDir = float3(0, 1, 0);
    float3 lightIntensity = float3(0);
    float maxSpotAngle = 0;
    float penumbra = 0.0;
    uint type = 0; //0 == Point, 1 == Area, 2 == Spot
    float lightArea = 1.f;
    
    if (analytic)
    {
        LightData currentLight = gScene.getLight(lightIndex);

        //we only support point lights
        if (currentLight.type != uint(LightType::Point))
            return;

        if (currentLight.openingAngle < (M_PI / 2.0))
            type = 2;
        
        lightPos = currentLight.posW;
        lightDir = currentLight.dirW;
        lightIntensity = currentLight.intensity;
        maxSpotAngle = currentLight.openingAngle;
        penumbra = currentLight.penumbraAngle;
    }
    //Emissive
    else
    {
        //invPdf = gEmissiveInvPdf[lightIndex]; //Assume all emissive triangles as pdf
        invPdf = kEmissiveInvPdf;
        const uint triIndex = lc.activeTriangles[lightIndex];
        EmissiveTriangle emiTri = lc.getTriangle(triIndex); //get the random triangle
        //random baycentric coordinates
        float2 RS = sampleNext2D(rayData.sg);
        const float3 barycentrics = sample_triangle(RS);
        lightPos = emiTri.getPosition(barycentrics);
        lightDir = emiTri.normal;
        lightArea = emiTri.area;

        //Evaluate Emitted radiance
        float2 uv = emiTri.getTexCoord(barycentrics);
        lightIntensity = gScene.materials.evalEmissive(emiTri.materialID, uv);
        lightIntensity *= kEmissiveScale;
        type = 1;
    }
    
    RayDesc ray;
    float lightDirPDF = 0.0;
    float3 lightRnd = sampleNext3D(rayData.sg);
    float spotAngle = maxSpotAngle - penumbra * lightRnd.z;
    calcLightDirection(lightDir, lightRnd.xy, ray.Direction, lightDirPDF, type, cos(spotAngle));

    //create photon
    float3 photonPos = float3(0, 0, 0);
    PhotonInfo photon;
    photon.dir = float3(0, 0, 0);
    photon.faceNTheta = 0.f;
    photon.flux = float3(0, 0, 0);
    photon.faceNPhi = 0.f;
    
    //light flux
    float3 lightFlux = (abs(dot(lightDir, ray.Direction)) * lightArea * lightIntensity * invPdf) / lightDirPDF;
    lightFlux /= float3(launchDim.x * launchDim.y);
    
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
        photon.flux = lightFlux * rayData.thp * rayData.cosTheta;
        TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        if(rayData.terminated)
            break;

        
        photonPos = rayData.origin;
        photon.dir = ray.Direction;
        reflectedDiffuse = rayData.diffuseHit;

        //rejection
        float rndRoulette = sampleNext1D(rayData.sg);
        bool roulette = rndRoulette <= kRussianRoulette;
        
        //save photon        
        if (reflectedDiffuse)
        {
            uint photonIndex = 0;
            float radius = wasReflectedSpecular ? gCausticRadius : gGlobalRadius;
            AABB photonAABB = calcPhotonAABB(photonPos, radius);
            //caustic photon
            if (wasReflectedSpecular)
            {
                InterlockedAdd(gPhotonCounter[0].caustic, 1u, photonIndex);
                photonIndex = min(photonIndex, kMaxPhotonIndexCAU);
                uint2 photonIndex2D = uint2(photonIndex / kInfoTexHeight, photonIndex % kInfoTexHeight);
                gCausticFlux[photonIndex2D] = float4(photon.flux, 1);
                gCausticDir[photonIndex2D] = float4(photon.dir, 1);
                gCausticAABB[photonIndex] = photonAABB;
            }
            //Global photon
            else if(roulette)
            {
                photon.flux /= kRussianRoulette;
                InterlockedAdd(gPhotonCounter[0].global, 1u, photonIndex);
                photonIndex = min(photonIndex, kMaxPhotonIndexGLB);
                uint2 photonIndex2D = uint2(photonIndex / kInfoTexHeight, photonIndex % kInfoTexHeight);
                gGlobalFlux[photonIndex2D] = float4(photon.flux, 1);
                gGlobalDir[photonIndex2D] = float4(photon.dir, 1);
                gGlobalAABB[photonIndex] = photonAABB;
            }
        }
   
        //Russian Roulette
        const float rrVal = luminance(rayData.thp);
        const float prob = max(0.f, 1.f - rrVal);
        float rnd = sampleNext1D(rayData.sg);
        if (rnd < prob)
        {
            break;      //Photon is absorbed
        }
        else
        {
            rayData.thp /= (1.f - prob);
        }

        wasReflectedSpecular = !reflectedDiffuse;
                
        //update ray for next iteration
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
    }
    
}

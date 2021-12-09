
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
        float pad1;
        float3 flux;
        float pad2;
 };

 //Internal Buffer Structs

RWStructuredBuffer<PhotonInfo> gCaustic;
RWStructuredBuffer<PhotonInfo> gGlobal;
RWStructuredBuffer<AABB> gCausticAABB;
RWStructuredBuffer<AABB> gGlobalAABB;


// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

/** Payload for scatter ray (80B).
*/
struct ScatterRayData
{
    float3  radiance;       ///< Accumulated outgoing radiance from path.
    bool    terminated;     ///< Set to true when path is terminated.
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint    pathLength;     ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3  origin;         ///< Next path segment origin.
    uint    _pad0;
    float3  direction;      ///< Next path segment direction.
    uint    _pad1;

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Create ray payload with default parameters.
    */
    static ScatterRayData create(SampleGenerator sg)
    {
        ScatterRayData d;
        d.terminated = false;
        d.pathLength = 0;
        d.radiance = float3(0, 0, 0);
        d.thp = float3(1, 1, 1);
        d.origin = float3(0, 0, 0);
        d.direction = float3(0, 0, 0);
        d.sg = sg;
        return d;
    }
};

[shader("miss")]
void miss(inout ScatterRayData rayData : SV_RayPayload)
{
    rayData.terminated = true;

    //TODO: Add enviroment map color if ray misses scene 
}

[shader("closesthit")]
void closestHit(inout ScatterRayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    uint currentIndex = launchIndex.x + launchDim.x * launchIndex.y;
    uint indexMax = launchDim.x * launchDim.y;
    
    AABB test;
    test.minPoint = float3(float(currentIndex) / float(indexMax), 0, 0);
    test.maxPoint = float3(2, 1, 1);

    gCausticAABB[currentIndex] = test;
    
    //gPhotonImage[launchIndex] = float4(float(currentIndex) / float(indexMax), 0, 0, 1);
    gPhotonImage[launchIndex] = float4(gCausticAABB[currentIndex].minPoint.x, 0, 0, 1);
}

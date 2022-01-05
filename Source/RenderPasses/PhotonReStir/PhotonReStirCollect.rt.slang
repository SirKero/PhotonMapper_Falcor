
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Utils.Math.MathHelpers;
import Experimental.Scene.Material.StandardMaterial;
import Experimental.Scene.Material.MaterialHelpers;
import Experimental.Scene.Lights.LightHelpers;


cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gCausticRadius; // Radius for the caustic photons
    float gGlobalRadius; // Radius for the global photons
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


// Outputs
RWTexture2D<float4> gPhotonImage;

//Internal Buffer Structs

struct PhotonInfo
{
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

// Static configuration based on defines set from the host.
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

/** Payload for ray (16B).
*/
struct RayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    bool terminated; ///< Set to true when path is terminated.
  
};


[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    rayData.terminated = true;
}

[shader("closesthit")]
void closestHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    gPhotonImage[launchIndex] = float4(1,0.0,0.0,1);
}

[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    
}

[shader("intersection")]
void intersection()
{

}

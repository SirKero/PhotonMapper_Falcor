#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Rendering.Materials.StandardMaterial;
import Rendering.Lights.LightHelpers;


cbuffer PerFrame
{
    float gPhotonRadius;    //Global photon radius
    uint gCurrentFrame;
    float gCosFov;
    uint gMaxBoxes;
}

Texture2D<PackedHitInfo> gVBuffer;

RWStructuredBuffer<uint> gAabbCounter;
RWStructuredBuffer<AABB> gAabbOut;

[numthreads(16, 16, 1)]
void main(uint2 DTid : SV_DispatchThreadID, uint2 Gid : SV_GroupID, uint2 GTid : SV_GroupThreadID, uint GI : SV_GroupIndex)
{
    uint2 texIndex = DTid;
    

    const HitInfo hit = HitInfo(gVBuffer[DTid]);

    if (!hit.isValid())
        return;
    
    const float3 pos = gScene.getVertexData(hit.getTriangleHit()).posW;
    
    float3 camPos = gScene.camera.getPosition();
    float3 camTarget = gScene.camera.data.target;

    float3 toTarget = normalize(camTarget - camPos);
    float3 toPos = normalize(pos - camPos);

    //insert box if it is outside of perspective camera
    if (dot(toTarget, toPos) < gCosFov)
    {
        uint aabbCount;
        InterlockedAdd(gAabbCounter[0], 1u, aabbCount);
        if (aabbCount < gMaxBoxes)
        {
            AABB aabb = AABB(pos - gPhotonRadius, pos + gPhotonRadius);
            gAabbOut[aabbCount] = aabb;

        }

    }    
}

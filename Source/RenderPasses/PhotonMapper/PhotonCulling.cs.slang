#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Rendering.Materials.StandardMaterial;
import Rendering.Lights.LightHelpers;

import PhotonCullingHash;

cbuffer PerFrame
{
    float gHashScaleFactor;    //Scale factor calculated from photon radius
    uint gHashSize;            //Size of the hash
    uint gYExtend;
    float gProjTest;            //Factor for the projection test 
}

static const bool kUseProjMatrixCulling = CULLING_USE_PROJECTION;

Texture2D<PackedHitInfo> gVBuffer;

RWTexture2D<uint> gHashBuffer;

[numthreads(16, 16, 1)]
void main(uint2 DTid : SV_DispatchThreadID, uint2 Gid : SV_GroupID, uint2 GTid : SV_GroupThreadID, uint GI : SV_GroupIndex)
{
    uint2 texIndex = DTid;
    

    const HitInfo hit = HitInfo(gVBuffer[DTid]);

    if (!hit.isValid())
        return;
    
    const float4 pos = float4(gScene.getVertexData(hit.getTriangleHit()).posW, 1);

    if(!kUseProjMatrixCulling){
        int3 cell = int3(floor(pos.xyz * gHashScaleFactor));
        uint h = hash(cell) & (gHashSize - 1);
        uint2 hIdx = uint2(h % gYExtend, h / gYExtend);
        gHashBuffer[hIdx] = 1;  //it does not matter if multiple threads write to one hash
    }
    else{
        float4 projPos = mul(pos, gScene.camera.getViewProj());
        projPos /= projPos.w;
    
        //insert box if it is outside of perspective camera
        if (any(abs(projPos.xy) > gProjTest) || projPos.z > 1.f || projPos.z < 0.f)
        {
            int3 cell = int3(floor(pos.xyz * gHashScaleFactor));
            uint h = hash(cell) & (gHashSize - 1);
            uint2 hIdx = uint2(h % gYExtend, h / gYExtend);
            gHashBuffer[hIdx] = 1;  //it does not matter if multiple threads write to one hash
        }
    }
}

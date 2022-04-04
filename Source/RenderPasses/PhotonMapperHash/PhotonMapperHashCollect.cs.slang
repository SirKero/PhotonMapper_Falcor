#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Rendering.Lights.LightHelpers;


cbuffer CB
{
    uint gFrameCount; // Frame count since scene was loaded.
    float gCausticRadius; // Radius for the caustic photons
    float gGlobalRadius; // Radius for the global photons
    bool gNoColorOutput; // Skips light calculation if activated and outputs 1 on all channels
    float gEmissiveScale; // Scale for the emissive part
    float gCausticHashScaleFactor; //Hash scale factor for caustic hash cells
    float gGlobalHashScaleFactor;
}

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
struct PhotonBucket
{
    uint size;
    int cell;
    uint2 pad;
    uint photonIdx[NUM_PHOTONS_PER_BUCKET];
};

struct PhotonInfo
{
    float3 dir;
    float faceNTheta;
    float3 flux;
    float faceNPhi;
};

 //Internal Buffer Structs
StructuredBuffer<PhotonBucket> gGlobalHashBucket;
StructuredBuffer<PhotonBucket> gCausticHashBucket;

RWTexture2D<float4> gCausticPos;
RWTexture2D<float4> gCausticFlux;
RWTexture2D<float4> gCausticDir;
RWTexture2D<float4> gGlobalPos;
RWTexture2D<float4> gGlobalFlux;
RWTexture2D<float4> gGlobalDir;


// Static configuration based on defines set from the host.
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

static const bool kCollectGlobalPhotons = COLLECT_GLOBAL_PHOTONS;
static const bool kCollectCausticPhotons = COLLECT_CAUSTIC_PHOTONS;
static const uint kInfoTexHeight = INFO_TEXTURE_HEIGHT;
static const uint kNumBuckets = NUM_BUCKETS; //Total number of buckets in 2^x

static const float kRayTMin = RAY_TMIN;
static const float kRayTMax = RAY_TMAX;

uint hash(int3 cell)
{
    //convert to uint64
    uint64_t key = 0;
    uint64_t cells = cell.x;
    cells &= 0xFFFFFFFF;
    key |= cells << 48;
    cells = cell.y;
    cells &= 0xFFFFFFFF;
    key |= cells << 32;
    key |= cell.z << 16;

    key = (~key) + (key << 18);
    key = key ^ (key >> 31);
    key *= 21;
    key = key ^ (key >> 11);
    key = key + (key << 6);
    uint res = uint(key) ^ uint(key >> 22);
    return res;
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    return gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);
}

float3 photonContribution(in ShadingData sd, uint photonIndex ,  bool isCaustic)
{
    const uint2 photonIndex2D = uint2(photonIndex / kInfoTexHeight, photonIndex % kInfoTexHeight);
    //get caustic or global photon
    PhotonInfo photon;
     //Instance 0 is always the caustic buffer
    if (isCaustic)
    {
        photon.flux = gCausticFlux[photonIndex2D].xyz;
        photon.dir = gCausticDir[photonIndex2D].xyz;
    }
    else
    {
        photon.flux = gGlobalFlux[photonIndex2D].xyz;
        photon.dir = gGlobalDir[photonIndex2D].xyz;
    }

    let lod = ExplicitLodTextureSampler(0.f);
    let bsdf = gScene.materials.getBSDF(sd, lod);
            
    float3 f_r = bsdf.eval(sd, -photon.dir);
     
    return f_r * photon.flux;
}

float3 collectPhotons(in HitInfo hitInfo, in float3 dirVec,bool isCaustic)
{
    float3 radiance = float3(0);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hitInfo, dirVec, lod);
    float radius = gCausticRadius;
    float scale = gCausticHashScaleFactor;
    int3 gridCenter = int3(floor(sd.posW * scale));
    int gridRadius = int(ceil(radius * scale));
    //Loop over whole hash grid

    for (int z = gridCenter.z - gridRadius; z <= gridCenter.z + gridRadius; z++){
        for (int y = gridCenter.y - gridRadius; y <= gridCenter.y + gridRadius; y++){
            for (int x = gridCenter.x - gridRadius; x <= gridCenter.x + gridRadius; x++)
            {
                
                uint b = hash(int3(x, y, z)) & (kNumBuckets - 1);
                uint d = 0;
                
                //Quadratic Probe with an maximum
                for (uint i = 0; i < 10; i++)
                {
                    int bucketSize = isCaustic ? gCausticHashBucket[b].size : gGlobalHashBucket[b].size;
                    int bucketCell = isCaustic ? gCausticHashBucket[b].cell : gGlobalHashBucket[b].cell;
                    //int cellXY = (x << 16) | (y & 0xFFFFFFFF);
                    int cellXY = x;
                    //Stop on empty bucket
                    if (bucketSize == 0)
                        break;
                    //If cell is the same collect all photons and stop loop for this cell at the end
                    
                    if (bucketCell == cellXY)
                    {
                        
                        uint photonCellIt = min(bucketSize, NUM_PHOTONS_PER_BUCKET);
                        float3 cellRadiance = float3(0);
                        for (int j = 0; j < photonCellIt; j++)
                        {
                            int photonIdx = isCaustic ? gCausticHashBucket[b].photonIdx[j] : gGlobalHashBucket[b].photonIdx[j];
                            cellRadiance += photonContribution(sd, photonIdx, isCaustic);
                        }
                        radiance += cellRadiance;
                        
                        break;  //Stop for this cell
                    }
                    
                    //quadratic probe next bucket
                    ++d;
                    b = (b + ((d + d * d) >> 1)) & (kNumBuckets - 1);
                }                
            }
        }
    }
    return radiance;
}

[numthreads(16, 16, 1)]
void main(uint2 DTid : SV_DispatchThreadID, uint2 Gid : SV_GroupID, uint2 GTid : SV_GroupThreadID, uint GI : SV_GroupIndex)
{
    float3 viewVec = gViewWorld[DTid].xyz;
    float4 thpMatID = gThpMatID[DTid];
    PackedHitInfo packedHitInfo = gVBuffer[DTid];
    const HitInfo hit = HitInfo(packedHitInfo);
    bool valid = hit.isValid(); //Check if the ray is valid
    float3 radiance = float3(0);
    
    
    if (kCollectCausticPhotons && valid)
    {
        float3 causticRadiance = collectPhotons(hit, viewVec, true);
        float w = 1 / (M_PI * gCausticRadius * gCausticRadius); //make this a constant
        radiance += w * causticRadiance;
    }
    
    /*    
    if (kCollectGlobalPhotons && valid)
    {
        float3 globalRadiance = collectPhotons(hit, viewVec, false);
        float w = 1 / (M_PI * gGlobalRadius * gGlobalRadius); //make this a constant
        radiance += w * globalRadiance;
    }
    */
    
    radiance *= thpMatID.xyz;   //Add throughput for path

    //Add emission
    float3 pixEmission = gEmissive[DTid].xyz;
    radiance += pixEmission * thpMatID.xyz;

     //Accumulate the image (Put in accumulate pass ? )
    if (gFrameCount > 0)
    {
        float3 last = gPhotonImage[DTid].xyz;
        float frameCountF = float(gFrameCount);
        last *= frameCountF;
        radiance += last;
        radiance /= frameCountF + 1.0;
    }
    
    gPhotonImage[DTid] = float4(radiance, 1);
}

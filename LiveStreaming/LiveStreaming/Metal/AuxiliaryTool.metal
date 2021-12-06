//
//  AuxiliaryTool.metal
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

#include <metal_stdlib>
using namespace metal;

kernel void assistTools(texture2d<float, access::read> videoTexture [[texture(0)]],
                        texture2d<float, access::write> destTexture [[texture(1)]],
                        constant uint *size [[ buffer(0) ]],
                        const uint2 threadPosInGrid [[thread_position_in_grid]])
{
//    if (threadPosInGrid.x >= size[0] || threadPosInGrid.y >= size[1]) {
//        return;
//    }
//    
    float4 assistColor = videoTexture.read(threadPosInGrid);
    destTexture.write(float4(assistColor.r, 0.0, 0.0, assistColor.a), threadPosInGrid);
}


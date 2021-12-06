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
                        constant int *type [[ buffer(1) ]],
                        const uint2 threadPosInGrid [[thread_position_in_grid]])
{
//    if (threadPosInGrid.x >= size[0] || threadPosInGrid.y >= size[1]) {
//        return;
//    }
//    
    float4 assistColor = videoTexture.read(threadPosInGrid);
    if (type[0] == 0) {
    } else if (type[0] == 1) {
        assistColor = float4(assistColor.r, 0.0, 0.0, assistColor.a);
    } else if (type[0] == 2) {
        assistColor = float4(0.0, assistColor.g, 0.0, assistColor.a);
    } else if (type[0] == 3) {
        assistColor = float4(0.0, 0.0, assistColor.b, assistColor.a);
    } else if (type[0] == 4) {
        float value = 0.2126 * assistColor.r + 0.7152 * assistColor.g + 0.0772 * assistColor.b;
        assistColor = float4(value, value, value, assistColor.a);
    }
    destTexture.write(assistColor, threadPosInGrid);
}


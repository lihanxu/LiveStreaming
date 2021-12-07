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

kernel void peak(texture2d<float, access::read> videoTexture [[texture(0)]],
                 texture2d<float, access::write> destTexture [[texture(1)]],
                 constant uint *size [[ buffer(0) ]],
                 constant int *state [[ buffer(1) ]],
                 const uint2 threadPosInGrid [[thread_position_in_grid]])
{
    float4 peakColor = float4(1.0, 1.0, 1.0, 1.0);
    float4 outputColor = float4(0.0, 0.0, 0.0, 0.0);
    
    if (state[0] == 0) {
        outputColor = videoTexture.read(threadPosInGrid);
    } else if (threadPosInGrid.x == size[0] - 1 || threadPosInGrid.y == size[1] - 1 || threadPosInGrid.x == 0 || threadPosInGrid.y == 0) {
        outputColor = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        float4 color;
        float yAdd = 0.0;
        float y = 0.0;
        // -1,-1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x - 1, threadPosInGrid.y - 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // 0,-1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x, threadPosInGrid.y - 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // 1,-1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x + 1, threadPosInGrid.y - 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // -1,0 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x - 1, threadPosInGrid.y));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // 0,0 --> 8
        color = videoTexture.read(uint2(threadPosInGrid.x, threadPosInGrid.y));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (8.0 * y);
        // 1,0 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x + 1, threadPosInGrid.y));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // -1,1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x - 1, threadPosInGrid.y + 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // 0,1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x, threadPosInGrid.y + 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        // 1,1 --> -1
        color = videoTexture.read(uint2(threadPosInGrid.x + 1, threadPosInGrid.y + 1));
        y = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b);
        yAdd = yAdd + (-1.0 * y);
        
        float peakSensitivity = 0.1;
        
        if (yAdd > peakSensitivity) {
            outputColor = peakColor;
        }
    }
    destTexture.write(outputColor, threadPosInGrid);
}

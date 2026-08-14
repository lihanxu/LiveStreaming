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
    float4 assistColor = videoTexture.read(threadPosInGrid);
    if (type[0] == 1) { // red 分量
        assistColor = float4(assistColor.r, 0.0, 0.0, assistColor.a);
    } else if (type[0] == 2) { // green 分量
        assistColor = float4(0.0, assistColor.g, 0.0, assistColor.a);
    } else if (type[0] == 3) { // blue 分量
        assistColor = float4(0.0, 0.0, assistColor.b, assistColor.a);
    } else if (type[0] == 4) { // rec.709 gray
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
        
        float peakSensitivity = 0.05;
        
        if (yAdd > peakSensitivity) {
            outputColor = peakColor;
        }
    }
    destTexture.write(outputColor, threadPosInGrid);
}

kernel void gaussianBlur(texture2d<float, access::read> videoTexture [[texture(0)]],
                 texture2d<float, access::write> destTexture [[texture(1)]],
                 constant uint *size [[ buffer(0) ]],
                 constant float *mask [[ buffer(1) ]],
                 const uint2 threadPosInGrid [[thread_position_in_grid]])
{
    float4 outputColor = float4(0.0, 0.0, 0.0, 0.0);
    float4 color = float4(0.0, 0.0, 0.0, 0.0);
    int r = 1;
    for (int y = -r; y <= r; y++) {
        for (int x = -r; x <= r; x++) {
            color = videoTexture.read(uint2(threadPosInGrid.x + x, threadPosInGrid.y + y));
            outputColor = outputColor + mask[(y+r)*(r*2+1) + x+r] * color;
        }
    }
    destTexture.write(outputColor, threadPosInGrid);
}

kernel void ColorLUT(texture2d<float, access::read> videoTexture [[texture(0)]],
                     texture2d<float, access::read> lutTexture [[texture(1)]],
                     texture2d<float, access::write> destTexture [[texture(2)]],
                     constant uint *size [[ buffer(0) ]],
                     const uint2 threadPosInGrid [[thread_position_in_grid]])
{
    if (threadPosInGrid.x >= size[0] || threadPosInGrid.y >= size[1]) {
        return;
    }
    
    const float4 colorAtPixel = videoTexture.read(threadPosInGrid);
    
    float R = colorAtPixel.r * 63.0;
    float G = colorAtPixel.g * 63.0;
    float B = colorAtPixel.b * 63.0;
    
    const int3 prevRGB = int3(int(R), int(G), int(B));
    const int3 nextRGB = int3((int(R) + 1) > 63 ? 63 : (int(R) + 1), (int(G) + 1) > 63 ? 63 : (int(G) + 1), (int(B) + 1) > 63 ? 63 : (int(B) + 1));
    const float3 d = float3(R - float(prevRGB.r), G - float(prevRGB.g), B - float(prevRGB.b));
    
    uint2 texPos000 = uint2((prevRGB.b % 8) * 64 + prevRGB.r, (prevRGB.b / 8) * 64 + prevRGB.g);
    uint2 texPos001 = uint2((nextRGB.b % 8) * 64 + prevRGB.r, (nextRGB.b / 8) * 64 + prevRGB.g);
    uint2 texPos010 = uint2((prevRGB.b % 8) * 64 + prevRGB.r, (prevRGB.b / 8) * 64 + nextRGB.g);
    uint2 texPos011 = uint2((nextRGB.b % 8) * 64 + prevRGB.r, (nextRGB.b / 8) * 64 + nextRGB.g);
    uint2 texPos100 = uint2((prevRGB.b % 8) * 64 + nextRGB.r, (prevRGB.b / 8) * 64 + prevRGB.g);
    uint2 texPos101 = uint2((nextRGB.b % 8) * 64 + nextRGB.r, (nextRGB.b / 8) * 64 + prevRGB.g);
    uint2 texPos110 = uint2((prevRGB.b % 8) * 64 + nextRGB.r, (prevRGB.b / 8) * 64 + nextRGB.g);
    uint2 texPos111 = uint2((nextRGB.b % 8) * 64 + nextRGB.r, (nextRGB.b / 8) * 64 + nextRGB.g);
    
    float4 c000 = lutTexture.read(texPos000);
    float4 c001 = lutTexture.read(texPos001);
    float4 c010 = lutTexture.read(texPos010);
    float4 c011 = lutTexture.read(texPos011);
    float4 c100 = lutTexture.read(texPos100);
    float4 c101 = lutTexture.read(texPos101);
    float4 c110 = lutTexture.read(texPos110);
    float4 c111 = lutTexture.read(texPos111);
    
    float3 c;
    if (d.r > d.g) {
        if (d.g > d.b) {
            c.r = (1.0-d.r) * c000.r + (d.r-d.g) * c100.r + (d.g-d.b) * c110.r + (d.b) * c111.r;
            c.g = (1.0-d.r) * c000.g + (d.r-d.g) * c100.g + (d.g-d.b) * c110.g + (d.b) * c111.g;
            c.b = (1.0-d.r) * c000.b + (d.r-d.g) * c100.b + (d.g-d.b) * c110.b + (d.b) * c111.b;
        } else if (d.r > d.b) {
            c.r = (1.0-d.r) * c000.r + (d.r-d.b) * c100.r + (d.b-d.g) * c101.r + (d.g) * c111.r;
            c.g = (1.0-d.r) * c000.g + (d.r-d.b) * c100.g + (d.b-d.g) * c101.g + (d.g) * c111.g;
            c.b = (1.0-d.r) * c000.b + (d.r-d.b) * c100.b + (d.b-d.g) * c101.b + (d.g) * c111.b;
        } else {
            c.r = (1.0-d.b) * c000.r + (d.b-d.r) * c001.r + (d.r-d.g) * c101.r + (d.g) * c111.r;
            c.g = (1.0-d.b) * c000.g + (d.b-d.r) * c001.g + (d.r-d.g) * c101.g + (d.g) * c111.g;
            c.b = (1.0-d.b) * c000.b + (d.b-d.r) * c001.b + (d.r-d.g) * c101.b + (d.g) * c111.b;
        }
    } else {
        if (d.b > d.g) {
            c.r = (1.0-d.b) * c000.r + (d.b-d.g) * c001.r + (d.g-d.r) * c011.r + (d.r) * c111.r;
            c.g = (1.0-d.b) * c000.g + (d.b-d.g) * c001.g + (d.g-d.r) * c011.g + (d.r) * c111.g;
            c.b = (1.0-d.b) * c000.b + (d.b-d.g) * c001.b + (d.g-d.r) * c011.b + (d.r) * c111.b;
        } else if (d.b > d.r) {
            c.r = (1.0-d.g) * c000.r + (d.g-d.b) * c010.r + (d.b-d.r) * c011.r + (d.r) * c111.r;
            c.g = (1.0-d.g) * c000.g + (d.g-d.b) * c010.g + (d.b-d.r) * c011.g + (d.r) * c111.g;
            c.b = (1.0-d.g) * c000.b + (d.g-d.b) * c010.b + (d.b-d.r) * c011.b + (d.r) * c111.b;
        } else {
            c.r = (1.0-d.g) * c000.r + (d.g-d.r) * c010.r + (d.r-d.b) * c110.r + (d.b) * c111.r;
            c.g = (1.0-d.g) * c000.g + (d.g-d.r) * c010.g + (d.r-d.b) * c110.g + (d.b) * c111.g;
            c.b = (1.0-d.g) * c000.b + (d.g-d.r) * c010.b + (d.r-d.b) * c110.b + (d.b) * c111.b;
        }
    }
    
    destTexture.write(float4(c, colorAtPixel.a), threadPosInGrid);
}

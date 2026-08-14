//
//  AuxiliaryTool.metal
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

#include <metal_stdlib>
using namespace metal;

// 单色 / 灰度：type 1=R 2=G 3=B 4=Rec.709 灰度
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

// Laplacian 高反差：邻域 8 点权重 -1、中心 +8，超过阈值画白边
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

// 3×3 高斯卷积：mask 由 CPU 归一化后传入
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

// 3D LUT：512×512 PNG = 8×8 个 64×64 切片。B 选切片，R/G 为切片内坐标，四面体插值。
kernel void ColorLUT(texture2d<float, access::read> videoTexture [[texture(0)]],
                     texture2d<float, access::read> lutTexture [[texture(1)]],
                     texture2d<float, access::write> destTexture [[texture(2)]],
                     constant uint *size [[ buffer(0) ]],
                     const uint2 threadPosInGrid [[thread_position_in_grid]])
{
    // size 必须是 uint32 宽高；越界线程直接返回，避免写坏目标纹理
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
    
    // 蓝通道决定 8×8 网格中的哪一块 64×64
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
    
    // 按 RGB 分数部分的大小关系选四面体，在立方体 8 个角点间插值
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

// 与 OFColorAdjustParams.gpuPacked 顺序一致；14 个 float 紧密排布
struct ColorAdjustParams {
    float exposure;
    float highlights;
    float shadows;
    float contrast;
    float brightness;
    float blacks;
    float saturation;
    float vibrance;
    float temperature;
    float tint;
    float sharpen;
    float clarity;
    float fade;
    float vignette;
};

/// Rec.709 亮度，高光/阴影/饱和都以它分区
static float rec709Luma(float3 rgb) {
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
}

/// 影调与色彩：曝光、高光、阴影、对比、亮度、黑点、饱和、自然饱和、色温、色调、褪色
kernel void colorAdjustTone(texture2d<float, access::read> videoTexture [[texture(0)]],
                            texture2d<float, access::write> destTexture [[texture(1)]],
                            constant uint *size [[ buffer(0) ]],
                            constant ColorAdjustParams &p [[ buffer(1) ]],
                            const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size[0] || gid.y >= size[1]) {
        return;
    }
    float4 src = videoTexture.read(gid);
    float3 rgb = src.rgb;
    
    // 1. 曝光（约 ±2EV）与亮度偏移
    rgb *= pow(2.0, p.exposure / 25.0);
    rgb += (p.brightness / 50.0) * 0.25;
    
    // 2. 绕中灰对比
    float contrast = 1.0 + (p.contrast / 50.0) * 0.8;
    rgb = (rgb - 0.5) * contrast + 0.5;
    
    // 3. 按 luma 分区做高光 / 阴影 / 黑点
    float luma = rec709Luma(rgb);
    float hiMask = smoothstep(0.45, 0.95, luma);
    float shMask = 1.0 - smoothstep(0.05, 0.55, luma);
    rgb += hiMask * (p.highlights / 50.0) * 0.35;
    rgb += shMask * (p.shadows / 50.0) * 0.35;
    
    float blackLift = p.blacks / 50.0;
    rgb = rgb + blackLift * 0.12 * (1.0 - luma);
    
    // 4. 饱和度；自然饱和度对低饱和像素加权更大
    luma = rec709Luma(rgb);
    float3 gray = float3(luma);
    rgb = mix(gray, rgb, 1.0 + p.saturation / 50.0);
    
    luma = rec709Luma(rgb);
    gray = float3(luma);
    float sat = clamp(distance(rgb, gray) * 2.0, 0.0, 1.0);
    float vib = 1.0 + (p.vibrance / 50.0) * (1.0 - sat);
    rgb = mix(gray, rgb, vib);
    
    // 5. 色温动 R/B，色调动绿↔品红
    float temp = p.temperature / 50.0 * 0.12;
    rgb.r += temp;
    rgb.b -= temp;
    float tint = p.tint / 50.0 * 0.10;
    rgb.g += tint;
    rgb.r -= tint * 0.5;
    rgb.b -= tint * 0.5;
    
    // 6. 褪色：抬中灰、压对比
    float fade = p.fade / 100.0;
    rgb = mix(rgb, float3(0.5), fade * 0.35);
    rgb = rgb * (1.0 - fade * 0.12) + fade * 0.10;
    
    destTexture.write(float4(clamp(rgb, 0.0, 1.0), src.a), gid);
}

/// 锐化 / 清晰度（反锐化掩模）+ 径向暗角
kernel void colorAdjustDetail(texture2d<float, access::read> videoTexture [[texture(0)]],
                              texture2d<float, access::write> destTexture [[texture(1)]],
                              constant uint *size [[ buffer(0) ]],
                              constant ColorAdjustParams &p [[ buffer(1) ]],
                              const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size[0] || gid.y >= size[1]) {
        return;
    }
    int2 pos = int2(gid);
    int2 maxPos = int2(size[0] - 1, size[1] - 1);
    float4 center4 = videoTexture.read(gid);
    float3 center = center4.rgb;
    
    // 1. 3×3 / 5×5 盒模糊，做反锐化掩模
    float3 blur3 = float3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            uint2 s = uint2(clamp(pos + int2(x, y), int2(0), maxPos));
            blur3 += videoTexture.read(s).rgb;
        }
    }
    blur3 /= 9.0;
    
    float3 blur5 = float3(0.0);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            uint2 s = uint2(clamp(pos + int2(x, y), int2(0), maxPos));
            blur5 += videoTexture.read(s).rgb;
        }
    }
    blur5 /= 25.0;
    
    // 2. 锐化用细核，清晰度用粗核
    float3 rgb = center;
    rgb += (center - blur3) * (p.sharpen / 100.0) * 1.6;
    rgb += (center - blur5) * (p.clarity / 50.0) * 0.9;
    
    // 3. 径向暗角，中心不受影响
    float2 uv = float2(gid) / float2(size[0], size[1]);
    float2 d = uv - float2(0.5);
    float r = length(d) / 0.75;
    float vig = smoothstep(0.35, 1.0, r) * (p.vignette / 100.0);
    rgb *= (1.0 - vig * 0.85);
    
    destTexture.write(float4(clamp(rgb, 0.0, 1.0), center4.a), gid);
}

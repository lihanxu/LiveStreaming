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

/// Rec.709 亮度；越界像素钳到画面内，避免边框假边缘。
static inline float peakLuma(texture2d<float, access::read> tex, uint2 pos, uint2 maxPos) {
    float4 c = tex.read(min(pos, maxPos));
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// 对 5×5 亮度窗口做 3×3 高斯，返回以 (cx, cy) 为中心的平滑值（cx/cy 取值 1…3）。
static inline float peakBlur3(thread const float n[5][5], int cx, int cy) {
    return (n[cy - 1][cx - 1] + 2.0 * n[cy - 1][cx] + n[cy - 1][cx + 1]
          + 2.0 * n[cy][cx - 1] + 4.0 * n[cy][cx] + 2.0 * n[cy][cx + 1]
          + n[cy + 1][cx - 1] + 2.0 * n[cy + 1][cx] + n[cy + 1][cx + 1]) * (1.0 / 16.0);
}

/// 边缘检测：先高斯去传感器噪点，再 Sobel；用局部对比度 + 尖峰抑制去掉孤立白点。
kernel void peak(texture2d<float, access::read> videoTexture [[texture(0)]],
                 texture2d<float, access::write> destTexture [[texture(1)]],
                 constant uint *size [[ buffer(0) ]],
                 constant int *state [[ buffer(1) ]],
                 const uint2 threadPosInGrid [[thread_position_in_grid]])
{
    float4 outputColor = float4(0.0, 0.0, 0.0, 1.0);

    if (state[0] == 0) {
        outputColor = videoTexture.read(threadPosInGrid);
        destTexture.write(outputColor, threadPosInGrid);
        return;
    }

    uint2 maxPos = uint2(size[0] - 1, size[1] - 1);
    // 5×5 窗口需要至少距边 2 像素
    if (threadPosInGrid.x < 2 || threadPosInGrid.y < 2
        || threadPosInGrid.x + 2 > maxPos.x || threadPosInGrid.y + 2 > maxPos.y) {
        destTexture.write(outputColor, threadPosInGrid);
        return;
    }

    // 1. 读 5×5 亮度，供后续高斯 / Sobel 复用，避免重复采样
    float n[5][5];
    for (int y = 0; y < 5; y++) {
        for (int x = 0; x < 5; x++) {
            n[y][x] = peakLuma(videoTexture, threadPosInGrid + uint2(x - 2, y - 2), maxPos);
        }
    }

    // 2. 内层 3×3 高斯平滑：压掉单像素噪点，真边缘对比度仍在
    float b[3][3];
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            b[y][x] = peakBlur3(n, x + 1, y + 1);
        }
    }

    // 3. Sobel 梯度幅值（比 Laplacian 更抗各向同性噪点）
    float gx = -b[0][0] + b[0][2] - 2.0 * b[1][0] + 2.0 * b[1][2] - b[2][0] + b[2][2];
    float gy = -b[0][0] - 2.0 * b[0][1] - b[0][2] + b[2][0] + 2.0 * b[2][1] + b[2][2];
    float mag = sqrt(gx * gx + gy * gy);

    // 4. 局部动态范围：平滑后仍几乎平坦的区域视为噪声，不画边
    float localMin = b[0][0];
    float localMax = b[0][0];
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            localMin = min(localMin, b[y][x]);
            localMax = max(localMax, b[y][x]);
        }
    }
    float localRange = localMax - localMin;

    // 5. 沿主梯度方向亮度应单调穿越中心；两侧同号是尖峰噪点，丢掉
    bool notSpike;
    if (abs(gx) >= abs(gy)) {
        notSpike = (b[1][0] - b[1][1]) * (b[1][2] - b[1][1]) < 0.0;
    } else {
        notSpike = (b[0][1] - b[1][1]) * (b[2][1] - b[1][1]) < 0.0;
    }

    // mag / range 阈值针对 1080p 前置传感器噪点：低于此多为皮肤纹理与 ISO 噪点
    constexpr float magThresh = 0.22;
    constexpr float rangeThresh = 0.10;
    if (notSpike && mag > magThresh && localRange > rangeThresh) {
        outputColor = float4(1.0, 1.0, 1.0, 1.0);
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

// 与 OFBeautyComputer 参数顺序一致：smooth, whitening, brightEyes, whiteTeeth
struct BeautyParams {
    float smooth;
    float whitening;
    float brightEyes;
    float whiteTeeth;
};

/// BeautifyFace 肤色启发式改成软权重。硬阈值会把鼻侧/眼窝阴影判成非皮肤，美白后变成黑斑。
static inline float beautySkinDetect(float3 c) {
    float r = c.r;
    float g = c.g;
    float b = c.b;
    float luma = rec709Luma(c);
    float chroma = max(max(r, g), b) - min(min(r, g), b);
    float tone = smoothstep(0.03, 0.14, luma);
    float warm = smoothstep(-0.04, 0.03, r - b);
    float rg = smoothstep(-0.05, 0.02, r - g);
    float ch = smoothstep(0.01, 0.05, chroma);
    return tone * mix(0.55, 1.0, warm * rg * ch);
}

/// 3×3 Sobel 边缘强度，替代完整 Canny
static inline float beautySobel(texture2d<float, access::read> src, uint2 gid, uint2 maxPos) {
    int2 p = int2(gid);
    int2 hi = int2(maxPos);
    float tl = rec709Luma(src.read(uint2(clamp(p + int2(-1, -1), int2(0), hi))).rgb);
    float t  = rec709Luma(src.read(uint2(clamp(p + int2( 0, -1), int2(0), hi))).rgb);
    float tr = rec709Luma(src.read(uint2(clamp(p + int2( 1, -1), int2(0), hi))).rgb);
    float l  = rec709Luma(src.read(uint2(clamp(p + int2(-1,  0), int2(0), hi))).rgb);
    float r  = rec709Luma(src.read(uint2(clamp(p + int2( 1,  0), int2(0), hi))).rgb);
    float bl = rec709Luma(src.read(uint2(clamp(p + int2(-1,  1), int2(0), hi))).rgb);
    float b  = rec709Luma(src.read(uint2(clamp(p + int2( 0,  1), int2(0), hi))).rgb);
    float br = rec709Luma(src.read(uint2(clamp(p + int2( 1,  1), int2(0), hi))).rgb);
    float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
    float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
    return length(float2(gx, gy));
}

/// 1/2 分辨率下采样，双边滤波在半分辨率上做，等效 texelSpacing≈4
kernel void beautyDownsample(texture2d<float, access::sample> videoTexture [[texture(0)]],
                             texture2d<float, access::write> destTexture [[texture(1)]],
                             const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destTexture.get_width() || gid.y >= destTexture.get_height()) {
        return;
    }
    float2 uv = (float2(gid) + 0.5) / float2(destTexture.get_width(), destTexture.get_height());
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    destTexture.write(videoTexture.sample(linearSampler, uv), gid);
}

/// 可分离双边水平 pass，权重与 GPUImageBilateralFilter 一致，distanceNormalizationFactor=4
kernel void beautyBilateralH(texture2d<float, access::read> srcTexture [[texture(0)]],
                             texture2d<float, access::write> destTexture [[texture(1)]],
                             const uint2 gid [[thread_position_in_grid]])
{
    uint w = destTexture.get_width();
    uint h = destTexture.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    const float weights[9] = {0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05};
    const float distNorm = 4.0;
    const int spacing = 2;
    int2 pos = int2(gid);
    int maxX = int(w) - 1;
    float3 center = srcTexture.read(gid).rgb;
    float3 sum = center * weights[4];
    float wsum = weights[4];
    for (int i = -4; i <= 4; i++) {
        if (i == 0) {
            continue;
        }
        uint x = uint(clamp(pos.x + i * spacing, 0, maxX));
        float3 sampleColor = srcTexture.read(uint2(x, gid.y)).rgb;
        float d = min(distance(center, sampleColor) * distNorm, 1.0);
        float gw = weights[i + 4] * (1.0 - d);
        sum += sampleColor * gw;
        wsum += gw;
    }
    destTexture.write(float4(sum / max(wsum, 1e-5), 1.0), gid);
}

/// 可分离双边垂直 pass
kernel void beautyBilateralV(texture2d<float, access::read> srcTexture [[texture(0)]],
                             texture2d<float, access::write> destTexture [[texture(1)]],
                             const uint2 gid [[thread_position_in_grid]])
{
    uint w = destTexture.get_width();
    uint h = destTexture.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    const float weights[9] = {0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05};
    const float distNorm = 4.0;
    const int spacing = 2;
    int2 pos = int2(gid);
    int maxY = int(h) - 1;
    float3 center = srcTexture.read(gid).rgb;
    float3 sum = center * weights[4];
    float wsum = weights[4];
    for (int i = -4; i <= 4; i++) {
        if (i == 0) {
            continue;
        }
        uint y = uint(clamp(pos.y + i * spacing, 0, maxY));
        float3 sampleColor = srcTexture.read(uint2(gid.x, y)).rgb;
        float d = min(distance(center, sampleColor) * distNorm, 1.0);
        float gw = weights[i + 4] * (1.0 - d);
        sum += sampleColor * gw;
        wsum += gw;
    }
    destTexture.write(float4(sum / max(wsum, 1e-5), 1.0), gid);
}

/// 按遮罩合成。磨皮对齐 BeautifyFace CombinationFilter：弱边缘且肤色才 mix 双边结果。
kernel void beautyApply(texture2d<float, access::read> videoTexture [[texture(0)]],
                        texture2d<float, access::sample> blurTexture [[texture(1)]],
                        texture2d<float, access::sample> maskTexture [[texture(2)]],
                        texture2d<float, access::write> destTexture [[texture(3)]],
                        constant uint *size [[ buffer(0) ]],
                        constant BeautyParams &p [[ buffer(1) ]],
                        const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size[0] || gid.y >= size[1]) {
        return;
    }
    float4 src4 = videoTexture.read(gid);
    float3 origin = src4.rgb;
    float3 rgb = origin;
    float2 uv = (float2(gid) + 0.5) / float2(size[0], size[1]);
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
    float skinMask = maskTexture.sample(linearSampler, uv).r;
    float3 maskHard = maskTexture.sample(nearestSampler, uv).rgb;
    float3 bilateral = blurTexture.sample(linearSampler, uv).rgb;
    
    // 1. 磨皮：弱边缘才 mix 双边
    float detect = beautySkinDetect(origin);
    float skin = skinMask * mix(0.80, 1.0, detect);
    float smoothW = p.smooth * skin;
    if (smoothW > 0.01) {
        uint2 maxPos = uint2(size[0] - 1, size[1] - 1);
        float edge = beautySobel(videoTexture, gid, maxPos);
        float edgeGate = 1.0 - smoothstep(0.12, 0.28, edge);
        float mixW = min(1.0, smoothW * edgeGate * 1.12);
        rgb = mix(origin, bilateral, mixW);
    }
    
    // 2. 美白：轻量 screen + 少量去红。强度打满也不整脸替换成灰白，避免煞白
    float whiteW = p.whitening * skinMask * 0.48;
    if (whiteW > 0.01) {
        float luma = rec709Luma(rgb);
        float lift = whiteW * (0.14 + 0.08 * (1.0 - luma));
        float3 lifted = rgb + (1.0 - rgb) * lift;
        float liftedLuma = rec709Luma(lifted);
        float3 fair = mix(lifted, float3(liftedLuma), 0.12);
        float redBias = max(0.0, fair.r - fair.g);
        fair.r -= redBias * 0.22;
        fair.b += redBias * 0.08;
        rgb = mix(rgb, fair, whiteW);
    }
    
    // 3. 亮眼：眼白明显提亮，虹膜略提；皮肤/眼皮偏暖则跳过
    if (p.brightEyes * maskHard.g > 0.01) {
        float luma = rec709Luma(rgb);
        float chroma = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);
        float warm = rgb.r - rgb.b;
        float skinLike = smoothstep(0.04, 0.10, warm) * smoothstep(0.08, 0.18, chroma);
        float sclera = smoothstep(0.32, 0.62, luma);
        float iris = (1.0 - sclera) * smoothstep(0.06, 0.28, luma);
        float eye = p.brightEyes * maskHard.g * (1.0 - skinLike);
        rgb += float3(0.13, 0.14, 0.18) * eye * sclera;
        rgb += float3(0.05, 0.055, 0.065) * eye * iris;
    }
    
    // 4. 白牙：去黄 + 可见提亮，舌头偏红排除
    if (p.whiteTeeth * maskHard.b > 0.01) {
        float luma = rec709Luma(rgb);
        float redBias = rgb.r - max(rgb.g, rgb.b);
        float yellow = max(0.0, (rgb.r + rgb.g) * 0.5 - rgb.b);
        float notTongue = 1.0 - smoothstep(0.06, 0.16, redBias);
        float brightEnough = smoothstep(0.16, 0.32, luma);
        float tw = p.whiteTeeth * maskHard.b * notTongue * brightEnough;
        float3 teeth = rgb;
        teeth.r -= yellow * 0.62 * tw;
        teeth.g -= yellow * 0.46 * tw;
        teeth.b += 0.12 * tw;
        teeth += 0.10 * tw;
        rgb = mix(rgb, teeth, tw);
    }
    
    destTexture.write(float4(clamp(rgb, 0.0, 1.0), src4.a), gid);
}

/// 把 origin 附近的像素吸向 target。weight 用 smoothstep 平方，避免圆斑硬边。
/// aspect 把 0…1 UV 拉成近似各向同性，避免竖屏脸被拉扁。
static inline float2 reshapeTranslate(float2 uv, float2 origin, float2 target, float radius, float intensity, float aspect) {
    if (abs(intensity) < 0.001 || radius < 1e-4) {
        return uv;
    }
    float2 d = uv - origin;
    d.x *= aspect;
    float dist = length(d);
    if (dist >= radius) {
        return uv;
    }
    float t = 1.0 - dist / radius;
    float weight = t * t * (3.0 - 2.0 * t);
    float2 move = target - origin;
    move.x *= aspect;
    move *= intensity * weight;
    move.x /= max(aspect, 1e-4);
    return uv - move;
}

/// 以 center 为圆心放大：采样点往中心收，画面上该区域被撑开。
static inline float2 reshapeEnlarge(float2 uv, float2 center, float radius, float intensity, float aspect) {
    if (abs(intensity) < 0.001 || radius < 1e-4) {
        return uv;
    }
    float2 d = uv - center;
    d.x *= aspect;
    float dist = length(d);
    if (dist >= radius) {
        return uv;
    }
    float t = dist / radius;
    float falloff = (1.0 - t) * (1.0 - t);
    float scale = 1.0 - intensity * falloff;
    d *= scale;
    d.x /= max(aspect, 1e-4);
    return center + d;
}

/// 面部重塑：按 MediaPipe 控制点做局部平移 / 放大。参数由 CPU 每帧写入，见 OFFaceReshapeComputer。
/// buffer1：0…5 强度，6 faceWidth（各向同性），8 起每两个 float 一个点。
kernel void faceReshape(texture2d<float, access::sample> videoTexture [[texture(0)]],
                        texture2d<float, access::write> destTexture [[texture(1)]],
                        constant uint *size [[buffer(0)]],
                        constant float *p [[buffer(1)]],
                        const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size[0] || gid.y >= size[1]) {
        return;
    }
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(size[0], size[1]);
    float aspect = float(size[0]) / max(float(size[1]), 1.0);

    float slimFace = p[0];
    float bigEye = p[1];
    float slimNose = p[2];
    float mouth = p[3];
    float hairline = p[4];
    float jaw = p[5];
    float faceW = max(p[6], 1e-4);

    float2 faceCenter = float2(p[8], p[9]);
    float2 chin = float2(p[10], p[11]);
    float2 leftCheek = float2(p[14], p[15]);
    float2 rightCheek = float2(p[16], p[17]);
    float2 leftEye = float2(p[18], p[19]);
    float2 rightEye = float2(p[20], p[21]);
    float2 leftAla = float2(p[22], p[23]);
    float2 rightAla = float2(p[24], p[25]);
    float2 mouthCenter = float2(p[26], p[27]);
    float2 leftMouth = float2(p[28], p[29]);
    float2 rightMouth = float2(p[30], p[31]);
    float2 leftJaw = float2(p[32], p[33]);
    float2 rightJaw = float2(p[34], p[35]);
    float2 hairOrigin = float2(p[36], p[37]);
    float2 hairTarget = float2(p[38], p[39]);
    float2 leftCheek2 = float2(p[40], p[41]);
    float2 rightCheek2 = float2(p[42], p[43]);
    float2 leftJaw2 = float2(p[44], p[45]);
    float2 rightJaw2 = float2(p[46], p[47]);

    // 强度可正可负：负值把像素往反方向推（胖脸、小眼、宽鼻、小嘴、发际线下移、下颌外扩）
    uv = reshapeTranslate(uv, hairOrigin, hairTarget, faceW * 0.42, hairline * 0.09, aspect);

    // 2. 下颌内收成 V：下颌角和下巴两侧往中线、略朝下巴收
    float2 jawTargetL = float2(mix(leftJaw.x, faceCenter.x, 0.55), mix(leftJaw.y, chin.y, 0.22));
    float2 jawTargetR = float2(mix(rightJaw.x, faceCenter.x, 0.55), mix(rightJaw.y, chin.y, 0.22));
    uv = reshapeTranslate(uv, leftJaw, jawTargetL, faceW * 0.30, jaw * 0.12, aspect);
    uv = reshapeTranslate(uv, rightJaw, jawTargetR, faceW * 0.30, jaw * 0.12, aspect);
    uv = reshapeTranslate(uv, leftJaw2, jawTargetL, faceW * 0.26, jaw * 0.09, aspect);
    uv = reshapeTranslate(uv, rightJaw2, jawTargetR, faceW * 0.26, jaw * 0.09, aspect);

    // 3. 瘦脸：脸颊水平吸向中线，第二圈点盖颧骨下方
    float2 cheekTargetL = float2(faceCenter.x, leftCheek.y);
    float2 cheekTargetR = float2(faceCenter.x, rightCheek.y);
    uv = reshapeTranslate(uv, leftCheek, cheekTargetL, faceW * 0.48, slimFace * 0.055, aspect);
    uv = reshapeTranslate(uv, rightCheek, cheekTargetR, faceW * 0.48, slimFace * 0.055, aspect);
    uv = reshapeTranslate(uv, leftCheek2, float2(faceCenter.x, leftCheek2.y), faceW * 0.40, slimFace * 0.035, aspect);
    uv = reshapeTranslate(uv, rightCheek2, float2(faceCenter.x, rightCheek2.y), faceW * 0.40, slimFace * 0.035, aspect);

    // 4. 瘦鼻：鼻翼水平吸向中线，避免把鼻尖拉歪
    uv = reshapeTranslate(uv, leftAla, float2(faceCenter.x, leftAla.y), faceW * 0.18, slimNose * 0.13, aspect);
    uv = reshapeTranslate(uv, rightAla, float2(faceCenter.x, rightAla.y), faceW * 0.18, slimNose * 0.13, aspect);

    // 5. 嘴巴：以唇心放大，嘴角跟着略撑开
    uv = reshapeEnlarge(uv, mouthCenter, faceW * 0.22, mouth * 0.07, aspect);
    uv = reshapeTranslate(uv, leftMouth, float2(mix(leftMouth.x, faceCenter.x, -0.35), leftMouth.y), faceW * 0.14, mouth * 0.05, aspect);
    uv = reshapeTranslate(uv, rightMouth, float2(mix(rightMouth.x, faceCenter.x, -0.35), rightMouth.y), faceW * 0.14, mouth * 0.05, aspect);

    // 6. 大眼放最后，避免被瘦脸把眼距挤乱
    uv = reshapeEnlarge(uv, leftEye, faceW * 0.16, bigEye * 0.18, aspect);
    uv = reshapeEnlarge(uv, rightEye, faceW * 0.16, bigEye * 0.18, aspect);

    destTexture.write(videoTexture.sample(linearSampler, uv), gid);
}

/// Rec.709 亮度，给漫画风在脸上按原图亮度压色块。
static inline float cartoonLuma(float3 c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// 漫画风合成：背景保留较多风格，脸部少风格 + 补高频，避免皮肤结块。
/// params: x=背景风格  y=脸部风格  z=细节回加  w=脸上亮度贴回
kernel void cartoonComposite(texture2d<float, access::sample> originalTexture [[texture(0)]],
                             texture2d<float, access::sample> cartoonTexture [[texture(1)]],
                             texture2d<float, access::sample> maskTexture [[texture(2)]],
                             texture2d<float, access::write> destTexture [[texture(3)]],
                             constant uint *size [[buffer(0)]],
                             constant float *params [[buffer(1)]],
                             const uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size[0] || gid.y >= size[1]) {
        return;
    }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = float2((float(gid.x) + 0.5) / float(size[0]),
                       (float(gid.y) + 0.5) / float(size[1]));
    float3 orig = originalTexture.sample(linearSampler, uv).rgb;
    float3 toon = cartoonTexture.sample(linearSampler, uv).rgb;
    float4 mask = maskTexture.sample(linearSampler, uv);
    float face = mask.r;
    float eye = mask.g;

    // 1. 3×3 高斯取低频，原图减低频得到五官边缘
    float2 texel = float2(1.0 / float(size[0]), 1.0 / float(size[1]));
    float3 blur = orig * 4.0;
    blur += originalTexture.sample(linearSampler, uv + float2(-texel.x, 0.0)).rgb * 2.0;
    blur += originalTexture.sample(linearSampler, uv + float2(texel.x, 0.0)).rgb * 2.0;
    blur += originalTexture.sample(linearSampler, uv + float2(0.0, -texel.y)).rgb * 2.0;
    blur += originalTexture.sample(linearSampler, uv + float2(0.0, texel.y)).rgb * 2.0;
    blur += originalTexture.sample(linearSampler, uv + float2(-texel.x, -texel.y)).rgb;
    blur += originalTexture.sample(linearSampler, uv + float2(texel.x, -texel.y)).rgb;
    blur += originalTexture.sample(linearSampler, uv + float2(-texel.x, texel.y)).rgb;
    blur += originalTexture.sample(linearSampler, uv + float2(texel.x, texel.y)).rgb;
    blur *= (1.0 / 16.0);
    float3 detail = orig - blur;

    // 2. 脸比背景更少用 GAN，眼睛再少一点，避免瞳孔被涂成色块
    float mixAmt = mix(params[0], params[1], face);
    mixAmt = mix(mixAmt, params[1] * 0.55, eye);
    float3 color = mix(orig, toon, mixAmt);

    // 3. 脸上用原图亮度去压 AnimeGAN 的平涂色阶
    float yOrig = cartoonLuma(orig);
    float yColor = max(cartoonLuma(color), 1e-4);
    float lumaBlend = face * params[3];
    color *= mix(1.0, yOrig / yColor, lumaBlend);

    // 4. 细节回加：全图轻度，脸上更强
    color += detail * params[2] * (0.28 + 0.72 * face);
    destTexture.write(float4(saturate(color), 1.0), gid);
}

//
//  AlbumScope.metal
//  LiveStreaming
//
//  相册示波器 P0：直方图 4×256 atomic，波形按列×电平累加。
//

#include <metal_stdlib>
using namespace metal;

constant float kRec709R = 0.2126;
constant float kRec709G = 0.7152;
constant float kRec709B = 0.0722;
constant uint kBins = 256;

/// 通道值映射到 0…255 档
static inline uint scopeBin(float channel) {
    return uint(clamp(round(channel * 255.0), 0.0, 255.0));
}

/// 直方图：R/G/B/Y 四个 256 档，layout 为 channel * 256 + bin
kernel void albumScopeHistogram(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *hist [[buffer(0)]],
    constant uint *size [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = size[0];
    uint height = size[1];
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    float4 px = src.read(gid);
    float r = px.r;
    uint rb = scopeBin(r);
    uint gb = scopeBin(px.g);
    uint bb = scopeBin(px.b);
    float y = kRec709R * r + kRec709G * px.g + kRec709B * px.b;
    uint yb = scopeBin(y);
    atomic_fetch_add_explicit(&hist[0 * kBins + rb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[1 * kBins + gb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[2 * kBins + bb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[3 * kBins + yb], 1u, memory_order_relaxed);
}

/// 波形：dens 为 R/G/B 三平面 `plane * 65536 + col * 256 + bin`；colorize 时 rgbSum 按亮度档
kernel void albumScopeWaveform(
    texture2d<float, access::read> src [[texture(0)]],
    device atomic_uint *dens [[buffer(0)]],
    device atomic_uint *rgbSum [[buffer(1)]],
    constant uint *size [[buffer(2)]],
    constant int *colorize [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = size[0];
    uint height = size[1];
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    float4 px = src.read(gid);
    uint col = gid.x * kBins / max(width, 1u);
    uint cells = kBins * kBins;
    uint rb = scopeBin(px.r);
    uint gb = scopeBin(px.g);
    uint bb = scopeBin(px.b);
    atomic_fetch_add_explicit(&dens[0u * cells + col * kBins + rb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&dens[1u * cells + col * kBins + gb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&dens[2u * cells + col * kBins + bb], 1u, memory_order_relaxed);
    float y = kRec709R * px.r + kRec709G * px.g + kRec709B * px.b;
    uint yb = scopeBin(y);
    atomic_fetch_add_explicit(&dens[3u * cells + col * kBins + yb], 1u, memory_order_relaxed);
    if (colorize[0] != 0) {
        uint idx = col * kBins + yb;
        atomic_fetch_add_explicit(&rgbSum[idx], uint(px.r * 255.0 + 0.5), memory_order_relaxed);
        atomic_fetch_add_explicit(&rgbSum[cells + idx], uint(px.g * 255.0 + 0.5), memory_order_relaxed);
        atomic_fetch_add_explicit(&rgbSum[cells * 2u + idx], uint(px.b * 255.0 + 0.5), memory_order_relaxed);
    }
}

//
//  AlbumScopeSnapshot.swift
//  LiveStreaming
//
//  示波器一帧测量结果：直方图计数与波形密度。UI 只读这份值，不持有 GPU。
//

import UIKit

/// 示波器当前展示种类
enum AlbumScopeKind: Int {
    /// 直方图：丢掉位置，只按电平计数
    case histogram = 0
    /// 波形：保留水平位置，纵轴为电平
    case waveform = 1
}

/// 波形通道：单通道或 RGB 叠画
enum AlbumScopeWaveformMode: Int {
    /// R/G/B 三通道叠在同一张图上
    case mixed = 0
    /// 只画红色电平
    case red = 1
    /// 只画绿色电平
    case green = 2
    /// 只画蓝色电平
    case blue = 3
}

/// 滤镜后一帧的直方图 + 波形累加结果
struct AlbumScopeSnapshot {
    /// 直方图 / 波形电平分档数
    static let binCount = 256
    /// 波形列数与电平档数（列 × 档）
    static let waveformSize = 256

    /// 红通道直方图；`bin i` 对应电平 `i/255`
    let histogramR: [UInt32]
    /// 绿通道直方图
    let histogramG: [UInt32]
    /// 蓝通道直方图
    let histogramB: [UInt32]
    /// Rec.709 亮度直方图
    let histogramY: [UInt32]
    /// 红通道波形密度，`col * 256 + bin`
    let waveformR: [UInt16]
    /// 绿通道波形密度
    let waveformG: [UInt16]
    /// 蓝通道波形密度
    let waveformB: [UInt16]
    /// Colorize 用的平均色 RGBA8888，按亮度档索引；未上色为 nil
    let waveformColor: [UInt8]?

    /// 空计数快照，GPU 失败时给 UI 一张空白图
    static func empty() -> AlbumScopeSnapshot {
        let bins = [UInt32](repeating: 0, count: binCount)
        let cells = waveformSize * binCount
        let wave = [UInt16](repeating: 0, count: cells)
        return AlbumScopeSnapshot(
            histogramR: bins,
            histogramG: bins,
            histogramB: bins,
            histogramY: bins,
            waveformR: wave,
            waveformG: wave,
            waveformB: wave,
            waveformColor: nil
        )
    }

    /// 把 256×256 密度画成同尺寸图；放大交给图层最近邻，禁止按屏幕像素 CPU 重采样（会卡死主线程）
    /// - Parameters:
    ///   - mode: 混合 / R / G / B
    ///   - colorize: 关=灰度；开则混合为 RGB 叠画、单通道为该通道色
    /// - Returns: 可给 `UIImageView` 的图
    func makeWaveformImage(mode: AlbumScopeWaveformMode, colorize: Bool) -> UIImage? {
        let bins = AlbumScopeSnapshot.binCount
        let cols = AlbumScopeSnapshot.waveformSize
        let count = cols * bins
        guard waveformR.count >= count, waveformG.count >= count, waveformB.count >= count else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let maxR = peak(waveformR)
        let maxG = peak(waveformG)
        let maxB = peak(waveformB)
        for y in 0..<bins {
            let bin = bins - 1 - y
            for x in 0..<cols {
                let src = x * bins + bin
                let dst = (y * cols + x) * 4
                switch mode {
                case .mixed:
                    let gR = contrast(waveformR[src], peak: maxR)
                    let gG = contrast(waveformG[src], peak: maxG)
                    let gB = contrast(waveformB[src], peak: maxB)
                    if colorize {
                        pixels[dst] = UInt8(gR * 255)
                        pixels[dst + 1] = UInt8(gG * 255)
                        pixels[dst + 2] = UInt8(gB * 255)
                    } else {
                        let gray = UInt8(max(gR, max(gG, gB)) * 255)
                        pixels[dst] = gray
                        pixels[dst + 1] = gray
                        pixels[dst + 2] = gray
                    }
                case .red:
                    writeSingle(waveformR[src], peak: maxR, tint: (255, 48, 48), colorize: colorize, into: &pixels, dst: dst)
                case .green:
                    writeSingle(waveformG[src], peak: maxG, tint: (40, 220, 70), colorize: colorize, into: &pixels, dst: dst)
                case .blue:
                    writeSingle(waveformB[src], peak: maxB, tint: (50, 110, 255), colorize: colorize, into: &pixels, dst: dst)
                }
                pixels[dst + 3] = 255
            }
        }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        guard let provider = CGDataProvider(data: data) else {
            return nil
        }
        guard let cgImage = CGImage(
            width: cols,
            height: bins,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cols * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// 单通道写入一个像素；无样本则保持黑
    /// - Parameters:
    ///   - dens: 该格密度
    ///   - peak: 该通道峰值
    ///   - tint: 上色时的通道色
    ///   - colorize: 是否上色
    ///   - pixels: RGBA 缓冲
    ///   - dst: 像素起始下标
    private func writeSingle(
        _ dens: UInt16,
        peak: Float,
        tint: (UInt8, UInt8, UInt8),
        colorize: Bool,
        into pixels: inout [UInt8],
        dst: Int
    ) {
        let gain = contrast(dens, peak: peak)
        if gain <= 0 {
            return
        }
        if colorize {
            pixels[dst] = UInt8(Float(tint.0) * gain)
            pixels[dst + 1] = UInt8(Float(tint.1) * gain)
            pixels[dst + 2] = UInt8(Float(tint.2) * gain)
        } else {
            let gray = UInt8(gain * 255)
            pixels[dst] = gray
            pixels[dst + 1] = gray
            pixels[dst + 2] = gray
        }
    }

    /// 线性对比：约 12% 峰值即打满，避免 sqrt 把弱计数抬成一层雾
    /// - Parameters:
    ///   - dens: 格子计数
    ///   - peak: 通道最大计数
    /// - Returns: 0…1
    private func contrast(_ dens: UInt16, peak: Float) -> Float {
        if dens == 0 {
            return 0
        }
        return min(1, Float(dens) / max(peak * 0.12, 1))
    }

    /// 密度峰值，至少为 1 以免除零
    /// - Parameter values: 波形密度
    /// - Returns: 最大计数
    private func peak(_ values: [UInt16]) -> Float {
        var maxDens: UInt16 = 1
        for value in values where value > maxDens {
            maxDens = value
        }
        return Float(maxDens)
    }
}

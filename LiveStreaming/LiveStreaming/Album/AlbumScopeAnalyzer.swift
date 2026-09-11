//
//  AlbumScopeAnalyzer.swift
//  LiveStreaming
//
//  示波器 GPU 旁路：滤镜后的 BGRA 降采样，直方图与波形一次提交。不改像素。
//

import Foundation
import Darwin
import Metal
import OFFilterKit
import CocoaLumberjack

/// 相册/直播共用的示波器累加器；关闭则 `analyze` 立即返回 nil
final class AlbumScopeAnalyzer {
    /// 分析长边上限（像素）；超过则先缩小再 atomic
    static let analysisMaxLongEdge: CGFloat = 512

    /// 面板打开时为 true；关闭则 `analyze` 立即返回 nil
    var isEnabled = false
    /// 波形 Colorize；关则不写 RGB 累加、快照无 `waveformColor`
    var colorize = false

    /// 与滤镜共用的 Metal 设备 / 队列 / 纹理缓存
    private let metal: OFDefalutMetal
    /// 直方图 pipeline
    private var histogramPipeline: MTLComputePipelineState?
    /// 波形 pipeline
    private var waveformPipeline: MTLComputePipelineState?
    /// `uint hist[4][256]`，shared 便于 CPU 读回
    private var histogramBuffer: MTLBuffer?
    /// 波形密度 `atomic_uint[3*256*256]`，平面顺序 R/G/B
    private var waveformDensBuffer: MTLBuffer?
    /// Colorize RGB 累加 `atomic_uint[3*256*256]`
    private var waveformRgbBuffer: MTLBuffer?
    /// Colorize 开关 int
    private var colorizeBuffer: MTLBuffer?

    /// - Parameter context: 相册 `OFAuxiliaryTools.context`，禁止另开 MTLDevice
    init(context: OFFilterContext) {
        metal = context.metal
        setupPipelines()
        setupBuffers()
    }

    /// 编译 App default library 里的两个 kernel
    private func setupPipelines() {
        guard let device = metal.device else {
            return
        }
        guard let library = device.makeDefaultLibrary() else {
            DDLogError("album scope: default metallib missing")
            return
        }
        do {
            if let histFn = library.makeFunction(name: "albumScopeHistogram") {
                histogramPipeline = try device.makeComputePipelineState(function: histFn)
            }
            if let waveFn = library.makeFunction(name: "albumScopeWaveform") {
                waveformPipeline = try device.makeComputePipelineState(function: waveFn)
            }
        } catch {
            DDLogError("album scope pipeline failed: \(error)")
        }
    }

    /// 分配 shared 累加缓冲；每帧 CPU memset 清零
    private func setupBuffers() {
        guard let device = metal.device else {
            return
        }
        let bins = AlbumScopeSnapshot.binCount
        let cells = AlbumScopeSnapshot.waveformSize * AlbumScopeSnapshot.binCount
        histogramBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.size * bins * 4,
            options: .storageModeShared
        )
        waveformDensBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.size * cells * 4,
            options: .storageModeShared
        )
        waveformRgbBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.size * cells * 3,
            options: .storageModeShared
        )
        var flag: Int32 = 0
        colorizeBuffer = device.makeBuffer(
            bytes: &flag,
            length: MemoryLayout<Int32>.size,
            options: .storageModeShared
        )
    }

    /// 对滤镜输出帧做直方图 + 波形；须在滤镜 `inputFrame` 之后、只读像素
    /// - Parameters:
    ///   - frame: 已着色的 BGRA 帧（分析只读）
    ///   - pool: 降采样输出池
    /// - Returns: 快照；关闭或 GPU 失败为 nil
    func analyze(frame: VideoFrame, pool: OFPixelBufferTool) -> AlbumScopeSnapshot? {
        guard isEnabled else {
            return nil
        }
        guard let histogramPipeline = histogramPipeline,
              let waveformPipeline = waveformPipeline,
              let histogramBuffer = histogramBuffer,
              let waveformDensBuffer = waveformDensBuffer,
              let waveformRgbBuffer = waveformRgbBuffer,
              let colorizeBuffer = colorizeBuffer,
              let commandQueue = metal.commandQueue,
              metal.videoTextureCache != nil,
              let source = frame.pixelBuffer else {
            return nil
        }
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        let scaled = AlbumMediaConverter.scaledSize(
            originalWidth: srcW,
            originalHeight: srcH,
            maxLongEdge: AlbumScopeAnalyzer.analysisMaxLongEdge
        )
        let even = AlbumMediaConverter.evenSize(width: scaled.0, height: scaled.1)
        var analysis = source
        if srcW != even.0 || srcH != even.1 {
            analysis = AlbumMediaConverter.scaledPixelBuffer(
                source,
                targetWidth: even.0,
                targetHeight: even.1,
                pool: pool
            ) ?? source
        }
        guard let texture = makeTexture(from: analysis) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(analysis)
        let height = CVPixelBufferGetHeight(analysis)
        // 1. CPU 清零共享缓冲（上一帧已 waitUntilCompleted）
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)
        memset(waveformDensBuffer.contents(), 0, waveformDensBuffer.length)
        if colorize {
            memset(waveformRgbBuffer.contents(), 0, waveformRgbBuffer.length)
        }
        var flag: Int32 = colorize ? 1 : 0
        memcpy(colorizeBuffer.contents(), &flag, MemoryLayout<Int32>.size)

        metal.updateTexture(width: width, height: height)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let sizeBuffer = metal.sizeBuffer,
              let groups = metal.numTreadGroups,
              let threads = metal.threadsPerGroup else {
            return nil
        }

        // 2. 同一 command buffer：直方图 + 波形
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(histogramPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            encoder.setBuffer(sizeBuffer, offset: 0, index: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(waveformPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(waveformDensBuffer, offset: 0, index: 0)
            encoder.setBuffer(waveformRgbBuffer, offset: 0, index: 1)
            encoder.setBuffer(sizeBuffer, offset: 0, index: 2)
            encoder.setBuffer(colorizeBuffer, offset: 0, index: 3)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeSnapshot()
    }

    /// CVPixelBuffer → bgra8 纹理，只读
    /// - Parameter pixelBuffer: 分析用 BGRA
    /// - Returns: MTLTexture
    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = metal.videoTextureCache else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture else {
            DDLogError("album scope texture failed: \(status)")
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// 把 GPU 缓冲拷成值类型；UInt32 密度夹到 UInt16
    private func makeSnapshot() -> AlbumScopeSnapshot? {
        guard let histogramBuffer = histogramBuffer,
              let waveformDensBuffer = waveformDensBuffer else {
            return nil
        }
        let bins = AlbumScopeSnapshot.binCount
        let histPtr = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: bins * 4)
        func copyHist(_ channel: Int) -> [UInt32] {
            var values = [UInt32](repeating: 0, count: bins)
            for i in 0..<bins {
                values[i] = histPtr[channel * bins + i]
            }
            return values
        }
        let cells = AlbumScopeSnapshot.waveformSize * AlbumScopeSnapshot.binCount
        let densPtr = waveformDensBuffer.contents().bindMemory(to: UInt32.self, capacity: cells * 4)
        func copyWave(_ plane: Int) -> [UInt16] {
            var luma = [UInt16](repeating: 0, count: cells)
            let base = plane * cells
            for i in 0..<cells {
                let raw = densPtr[base + i]
                luma[i] = raw > UInt32(UInt16.max) ? UInt16.max : UInt16(raw)
            }
            return luma
        }
        var color: [UInt8]?
        if colorize, let waveformRgbBuffer = waveformRgbBuffer {
            let rgbPtr = waveformRgbBuffer.contents().bindMemory(to: UInt32.self, capacity: cells * 3)
            var rgba = [UInt8](repeating: 0, count: cells * 4)
            for i in 0..<cells {
                let d = densPtr[cells * 3 + i]
                if d == 0 {
                    continue
                }
                let r = rgbPtr[i] / d
                let g = rgbPtr[cells + i] / d
                let b = rgbPtr[cells * 2 + i] / d
                let base = i * 4
                rgba[base] = UInt8(min(r, 255))
                rgba[base + 1] = UInt8(min(g, 255))
                rgba[base + 2] = UInt8(min(b, 255))
                rgba[base + 3] = 255
            }
            color = rgba
        }
        return AlbumScopeSnapshot(
            histogramR: copyHist(0),
            histogramG: copyHist(1),
            histogramB: copyHist(2),
            histogramY: copyHist(3),
            waveformR: copyWave(0),
            waveformG: copyWave(1),
            waveformB: copyWave(2),
            waveformColor: color
        )
    }
}

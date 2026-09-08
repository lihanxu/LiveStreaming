//
//  OFColorAdjustComputer.swift
//  LiveStreaming
//
//  调色节点：一个处理图顶点，内部 tone + 可选 spatial 两个 kernel。
//

import Foundation
import Metal
import CocoaLumberjack

/// 全局调色处理节点。
public class OFColorAdjustComputer: NSObject, OFProcessNode {
    /// 本实例 Metal 上下文
    private let defalutMetal: OFDefalutMetal
    /// 本实例输出缓冲池
    private let pixelBufferPool: OFPixelBufferTool
    /// 影调 / 色彩 kernel
    private var tonePipeline: MTLComputePipelineState?
    /// 锐化 / 清晰度 / 暗角 kernel
    private var detailPipeline: MTLComputePipelineState?
    /// 传给 GPU 的参数，与 OFColorAdjustParams.gpuPacked 对齐
    private var paramsBuffer: MTLBuffer?
    /// 当前参数
    private var params = OFColorAdjustParams()
    /// 保护 params / GPU buffer，设置页与采集线程可能同时访问
    private let paramsLock = NSLock()
    /// 按住对比时为 true，节点跳过但参数保留
    private var bypassed = false
    
    /// 有任意非零滑杆才执行；对比按住时跳过
    public var isEnabled: Bool {
        paramsLock.lock()
        let identity = params.isIdentity
        let skip = bypassed
        paramsLock.unlock()
        return !skip && !identity && tonePipeline != nil
    }
    
    /// 创建节点并编译两个 kernel
    /// - Parameter context: 门面注入的 GPU 资源
    public init(context: OFFilterContext) {
        self.defalutMetal = context.metal
        self.pixelBufferPool = context.pixelBufferPool
        super.init()
        setupMetal()
        syncParamsBuffer()
    }
    
    /// 当前参数副本，供设置页展示
    public var currentParams: OFColorAdjustParams {
        paramsLock.lock()
        let copy = params
        paramsLock.unlock()
        return copy
    }
    
    /// 设置页改某一项后调用
    /// - Parameter newParams: 完整参数
    public func updateParams(_ newParams: OFColorAdjustParams) {
        paramsLock.lock()
        params = newParams
        syncParamsBuffer()
        paramsLock.unlock()
    }
    
    /// 全部滑杆归零
    public func resetParams() {
        paramsLock.lock()
        params = OFColorAdjustParams()
        syncParamsBuffer()
        paramsLock.unlock()
    }
    
    /// 对比原片：不改参数，只决定这一帧是否跑 kernel
    /// - Parameter bypassed: true 时透传
    public func setBypassed(_ bypassed: Bool) {
        paramsLock.lock()
        self.bypassed = bypassed
        paramsLock.unlock()
    }
    
    /// 编译 colorAdjustTone / colorAdjustDetail
    private func setupMetal() {
        let library = defalutMetal.makeShaderLibrary()
        guard let toneFn = library?.makeFunction(name: "colorAdjustTone"),
              let detailFn = library?.makeFunction(name: "colorAdjustDetail") else {
            DDLogError("color adjust kernels not found")
            return
        }
        do {
            tonePipeline = try defalutMetal.device?.makeComputePipelineState(function: toneFn)
            detailPipeline = try defalutMetal.device?.makeComputePipelineState(function: detailFn)
            DDLogInfo("color adjust pipelines ready")
        } catch {
            DDLogError("create color adjust pipeline failed: \(error)")
        }
    }
    
    /// 把 14 个 float 写进 GPU buffer
    private func syncParamsBuffer() {
        let packed = params.gpuPacked()
        paramsBuffer = defalutMetal.device?.makeBuffer(
            bytes: packed,
            length: packed.count * MemoryLayout<Float>.size,
            options: []
        )
    }
    
    /// 从 pixel buffer 包 Metal 纹理，需保留 CVMetalTexture
    /// - Parameter pixelBuffer: BGRA 缓冲
    /// - Returns: 包装对；失败为 nil
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let textureCache = defalutMetal.videoTextureCache else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            DDLogError("color adjust texture wrap failed, status:\(status)")
            return nil
        }
        return (cvTexture, texture)
    }
    
    /// 对当前帧做调色；需要邻域时在同一 command buffer 里再跑 detail
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    public func process(_ frame: VideoFrame) {
        paramsLock.lock()
        let snapshot = params
        paramsLock.unlock()
        guard !snapshot.isIdentity, let tonePipeline = tonePipeline, let paramsBuffer = paramsBuffer else {
            return
        }
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        
        let sourcePair: (CVMetalTexture, MTLTexture)?
        if frame.texture != nil {
            sourcePair = nil
        } else {
            sourcePair = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        }
        guard let sourceTexture = sourcePair?.1 ?? frame.texture else {
            return
        }
        
        guard let tonePixelBuffer = pixelBufferPool.createPixelBuffer(),
              let tonePair = createTextureFromPixelBuffer(pixelBuffer: tonePixelBuffer),
              let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            return
        }
        
        // 1. 影调与色彩：源 → tone 缓冲
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(tonePipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(tonePair.1, index: 1)
            encoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
            encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }
        
        var outputPixelBuffer = tonePixelBuffer
        var outputTexture = tonePair.1
        var detailPair: (CVMetalTexture, MTLTexture)?
        
        // 2. 锐化 / 清晰度 / 暗角：tone → 第二块缓冲
        if snapshot.needsSpatialPass, let detailPipeline = detailPipeline {
            guard let detailPixelBuffer = pixelBufferPool.createPixelBuffer(),
                  let wrapped = createTextureFromPixelBuffer(pixelBuffer: detailPixelBuffer),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            detailPair = wrapped
            encoder.setComputePipelineState(detailPipeline)
            encoder.setTexture(tonePair.1, index: 0)
            encoder.setTexture(wrapped.1, index: 1)
            encoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
            encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            outputPixelBuffer = detailPixelBuffer
            outputTexture = wrapped.1
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            DDLogError("color adjust status:\(commandBuffer.status.rawValue)")
            return
        }
        
        frame.pixelBuffer = outputPixelBuffer
        frame.texture = outputTexture
        _ = sourcePair
        _ = tonePair
        _ = detailPair
    }
}

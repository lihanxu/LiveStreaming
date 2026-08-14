//
//  OFBeautyComputer.swift
//  LiveStreaming
//
//  美颜节点：磨皮、美白、亮眼、白牙。
//  磨皮对齐 BeautifyFaceDemo：半分辨率可分离双边 + Sobel 保边 + 肤色检测。
//  美白用同一套 log 曲线；亮眼/白牙仍靠关键点遮罩。
//

import Foundation
import Metal
import CocoaLumberjack

/// 处理图中的美颜滤镜。
class OFBeautyComputer: NSObject, OFProcessNode {
    /// 共享 Metal 上下文
    private let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 输出缓冲池
    private let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// 全图下采样到 1/2，给双边滤波用
    private var downsamplePipeline: MTLComputePipelineState?
    /// 半分辨率水平双边
    private var blurHPipeline: MTLComputePipelineState?
    /// 半分辨率垂直双边
    private var blurVPipeline: MTLComputePipelineState?
    /// 按遮罩合成四项效果
    private var applyPipeline: MTLComputePipelineState?
    /// smooth / whitening / brightEyes / whiteTeeth，与 Metal BeautyParams 对齐
    private var paramsBuffer: MTLBuffer?
    /// 当前档位强度
    private var smooth: Float = 0
    /// 美白强度 0…1
    private var whitening: Float = 0
    /// 亮眼强度 0…1
    private var brightEyes: Float = 0
    /// 白牙强度 0…1
    private var whiteTeeth: Float = 0
    /// 总开关
    private var masterEnabled = false
    /// 保护参数，设置页与采集线程可能同时访问
    private let lock = NSLock()
    /// 人脸关键点来源
    weak var landmarker: OFFaceLandmarkerComputer?
    /// 皮肤/眼睛/牙齿遮罩
    private var regionMask: OFFaceRegionMask?
    /// 下采样宽
    private var blurWidth = 0
    /// 下采样高
    private var blurHeight = 0
    /// 水平模糊中间纹理
    private var blurTemp: MTLTexture?
    /// 低频磨皮纹理
    private var blurLow: MTLTexture?
    
    /// 总开关打开、有非零项、pipeline 就绪才跑
    var isEnabled: Bool {
        lock.lock()
        let on = masterEnabled && !isIdentityLocked()
        lock.unlock()
        return on && applyPipeline != nil
    }
    
    /// 创建节点、编译 kernel、分配遮罩
    override init() {
        super.init()
        regionMask = OFFaceRegionMask(device: defalutMetal.device)
        setupMetal()
        syncParamsBuffer()
    }
    
    /// 设置页改档位后调用
    /// - Parameter settings: 美颜状态
    func applySettings(_ settings: OFBeautySettings) {
        lock.lock()
        masterEnabled = settings.isEnabled
        smooth = settings.smooth.gpuStrength
        whitening = settings.whitening.gpuStrength
        brightEyes = settings.brightEyes.gpuStrength
        whiteTeeth = settings.whiteTeeth.gpuStrength
        syncParamsBuffer()
        lock.unlock()
    }
    
    /// 编译下采样 / 高斯 / 合成 kernel
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        guard let downFn = library?.makeFunction(name: "beautyDownsample"),
              let blurHFn = library?.makeFunction(name: "beautyBilateralH"),
              let blurVFn = library?.makeFunction(name: "beautyBilateralV"),
              let applyFn = library?.makeFunction(name: "beautyApply") else {
            DDLogError("beauty kernels not found")
            return
        }
        do {
            downsamplePipeline = try defalutMetal.device?.makeComputePipelineState(function: downFn)
            blurHPipeline = try defalutMetal.device?.makeComputePipelineState(function: blurHFn)
            blurVPipeline = try defalutMetal.device?.makeComputePipelineState(function: blurVFn)
            applyPipeline = try defalutMetal.device?.makeComputePipelineState(function: applyFn)
            DDLogInfo("beauty pipelines ready")
        } catch {
            DDLogError("create beauty pipeline failed: \(error)")
        }
    }
    
    /// 调用方已持有 lock
    private func isIdentityLocked() -> Bool {
        return smooth < 0.001 && whitening < 0.001 && brightEyes < 0.001 && whiteTeeth < 0.001
    }
    
    /// 把 4 个 float 写进已有 GPU buffer，避免每帧重新分配
    private func syncParamsBuffer() {
        let packed: [Float] = [smooth, whitening, brightEyes, whiteTeeth]
        let byteCount = packed.count * MemoryLayout<Float>.size
        if paramsBuffer == nil || (paramsBuffer?.length ?? 0) < byteCount {
            paramsBuffer = defalutMetal.device?.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        packed.withUnsafeBytes { src in
            if let dest = paramsBuffer?.contents(), let base = src.baseAddress {
                memcpy(dest, base, byteCount)
            }
        }
    }
    
    /// 按全图尺寸准备 1/2 双边滤波纹理
    /// - Parameters:
    ///   - width: 全图宽
    ///   - height: 全图高
    private func ensureBlurTextures(width: Int, height: Int) {
        let nextW = max(1, width / 2)
        let nextH = max(1, height / 2)
        guard nextW != blurWidth || nextH != blurHeight || blurTemp == nil || blurLow == nil else {
            return
        }
        blurWidth = nextW
        blurHeight = nextH
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: nextW,
            height: nextH,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        blurTemp = defalutMetal.device?.makeTexture(descriptor: desc)
        blurLow = defalutMetal.device?.makeTexture(descriptor: desc)
    }
    
    /// 按纹理尺寸派发 16×16 线程组
    /// - Parameters:
    ///   - encoder: 当前 encoder
    ///   - width: 目标宽
    ///   - height: 目标高
    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        let threads = MTLSizeMake(16, 16, 1)
        let groups = MTLSizeMake(
            (width + 15) / 16,
            (height + 15) / 16,
            1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }
    
    /// 从 pixel buffer 包 Metal 纹理
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
            return nil
        }
        return (cvTexture, texture)
    }
    
    /// 有人脸时按遮罩做磨皮/美白/亮眼/白牙
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    func process(_ frame: VideoFrame) {
        lock.lock()
        let needBlur = smooth > 0.001
        lock.unlock()
        guard let applyPipeline = applyPipeline, let paramsBuffer = paramsBuffer else {
            return
        }
        let faces = landmarker?.copyLatestFaces() ?? []
        guard let face = faces.first, regionMask?.update(face: face) == true, let maskTexture = regionMask?.texture else {
            return
        }
        
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        ensureBlurTextures(width: frame.frameWidth, height: frame.frameHeight)
        
        let sourcePair: (CVMetalTexture, MTLTexture)?
        if frame.texture != nil {
            sourcePair = nil
        } else {
            sourcePair = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        }
        guard let sourceTexture = sourcePair?.1 ?? frame.texture else {
            return
        }
        guard let outPixelBuffer = pixelBufferPool.createPixelBuffer(),
              let outPair = createTextureFromPixelBuffer(pixelBuffer: outPixelBuffer),
              let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer() else {
            return
        }
        
        // 1. 磨皮：1/2 下采样 + 可分离双边；其它项仍绑定原图，shader 里按强度跳过
        var blurTexture: MTLTexture = sourceTexture
        if needBlur,
           let downsamplePipeline = downsamplePipeline,
           let blurHPipeline = blurHPipeline,
           let blurVPipeline = blurVPipeline,
           let blurTemp = blurTemp,
           let blurLow = blurLow {
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(downsamplePipeline)
                encoder.setTexture(sourceTexture, index: 0)
                encoder.setTexture(blurTemp, index: 1)
                dispatch(encoder, width: blurWidth, height: blurHeight)
                encoder.endEncoding()
            }
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(blurHPipeline)
                encoder.setTexture(blurTemp, index: 0)
                encoder.setTexture(blurLow, index: 1)
                dispatch(encoder, width: blurWidth, height: blurHeight)
                encoder.endEncoding()
            }
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(blurVPipeline)
                encoder.setTexture(blurLow, index: 0)
                encoder.setTexture(blurTemp, index: 1)
                dispatch(encoder, width: blurWidth, height: blurHeight)
                encoder.endEncoding()
            }
            blurTexture = blurTemp
        }
        
        // 2. 全分辨率按遮罩合成
        guard let encoder = commandBuffer.makeComputeCommandEncoder(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            return
        }
        encoder.setComputePipelineState(applyPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(blurTexture, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        encoder.setTexture(outPair.1, index: 3)
        encoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            DDLogError("beauty status:\(commandBuffer.status.rawValue)")
            return
        }
        frame.pixelBuffer = outPixelBuffer
        frame.texture = outPair.1
        _ = sourcePair
        _ = outPair
    }
}

//
//  OFBeautyComputer.swift
//  LiveStreaming
//
//  美颜节点：磨皮、美肤 LUT、亮眼、白牙。
//  磨皮对齐 BeautifyFaceDemo：半分辨率可分离双边 + Sobel 保边 + 肤色检测。
//  合成后再加 origin−双边 的小幅残差，把毛孔量级质感贴回，斑点大幅残差仍丢掉。
//  美肤：冷白 / 暖白 / 粉嫩三张 3D LUT，滑杆只控制原图与滤镜色的 mix。
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
    /// 与 Metal BeautyParams 对齐：磨皮 / 美肤强度 / 亮眼 / 白牙
    private var paramsBuffer: MTLBuffer?
    /// 当前档位强度
    private var smooth: Float = 0
    /// 美肤 LUT 混合 0…1
    private var whitening: Float = 0
    /// 亮眼强度 0…1
    private var brightEyes: Float = 0
    /// 白牙强度 0…1
    private var whiteTeeth: Float = 0
    /// 当前美肤 LUT；风格切换后替换
    private var skinLutTexture: MTLTexture?
    /// 已加载的 LUT 资源名，避免重复读 PNG
    private var loadedLutName: String?
    /// 无人脸时给 shader 的空遮罩（全 0）
    private var emptyMask: MTLTexture?
    /// 总开关
    private var masterEnabled = false
    /// 按住对比时为 true，节点跳过但参数保留
    private var bypassed = false
    /// 保护参数，设置页与采集线程可能同时访问
    private let lock = NSLock()
    /// 人脸关键点来源
    weak var landmarker: OFFaceLandmarkerComputer?
    /// 皮肤/眼睛/牙齿遮罩
    private var regionMask: OFFaceRegionMask?
    /// 距上次重绘遮罩的帧数
    private var framesSinceMask = 100
    /// 鼻尖，用来判断脸是否明显移动
    private var lastNose = CGPoint.zero
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
        let on = masterEnabled && !isIdentityLocked() && !bypassed
        lock.unlock()
        return on && applyPipeline != nil
    }
    
    /// 创建节点、编译 kernel、分配遮罩
    override init() {
        super.init()
        regionMask = OFFaceRegionMask(device: defalutMetal.device)
        makeEmptyMask()
        setupMetal()
        loadSkinLUT(named: OFWhiteningStyle.warm.lutFileName)
        syncParamsBuffer()
    }
    
    /// 设置页改档位后调用
    /// - Parameter settings: 美颜状态
    func applySettings(_ settings: OFBeautySettings) {
        lock.lock()
        masterEnabled = settings.isEnabled
        smooth = OFBeautySettings.toneGpuStrength(settings.smooth, key: .smooth)
        whitening = OFBeautySettings.toneGpuStrength(settings.whitening, key: .whitening)
        brightEyes = OFBeautySettings.toneGpuStrength(settings.brightEyes, key: .brightEyes)
        whiteTeeth = OFBeautySettings.toneGpuStrength(settings.whiteTeeth, key: .whiteTeeth)
        loadSkinLUT(named: settings.whiteningStyle.lutFileName)
        syncParamsBuffer()
        lock.unlock()
    }
    
    /// 对比原片：不改参数，只决定这一帧是否跑 kernel
    /// - Parameter bypassed: true 时透传
    func setBypassed(_ bypassed: Bool) {
        lock.lock()
        self.bypassed = bypassed
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
    
    /// 1×1 全 0 遮罩，无人脸时磨皮/亮眼/白牙权重为 0，美肤 LUT 仍可全图 mix
    private func makeEmptyMask() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        emptyMask = defalutMetal.device?.makeTexture(descriptor: desc)
        var pixel: UInt32 = 0
        emptyMask?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }
    
    /// 按风格加载美肤色表；同名则跳过
    /// - Parameter name: Bundle 中 PNG 名
    private func loadSkinLUT(named name: String) {
        if loadedLutName == name, skinLutTexture != nil {
            return
        }
        guard let device = defalutMetal.device else {
            return
        }
        skinLutTexture = OFLUTLoader.loadTexture(named: name, device: device)
        loadedLutName = name
        if skinLutTexture == nil {
            DDLogError("skin LUT load failed: \(name)")
        }
    }
    
    /// 调用方已持有 lock
    private func isIdentityLocked() -> Bool {
        return smooth < 0.001 && whitening < 0.001 && brightEyes < 0.001 && whiteTeeth < 0.001
    }
    
    /// 把 BeautyParams 写进已有 GPU buffer，避免每帧重新分配
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
    
    /// 鼻尖明显移动，或隔了三帧，才重绘遮罩；避免每帧扫描线填充拖垮预览
    /// - Parameter face: 当前关键点
    /// - Returns: 是否需要栅格化
    private func shouldRebuildMask(face: [CGPoint]) -> Bool {
        framesSinceMask += 1
        let nose = face.count > 1 ? face[1] : .zero
        let dx = nose.x - lastNose.x
        let dy = nose.y - lastNose.y
        let moved = (dx * dx + dy * dy) > 0.000064
        if framesSinceMask >= 3 || moved || regionMask?.texture == nil {
            lastNose = nose
            framesSinceMask = 0
            return true
        }
        return false
    }
    
    /// 磨皮/亮眼/白牙跟人脸遮罩；美肤 LUT 无人脸也可以全图 mix
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    func process(_ frame: VideoFrame) {
        lock.lock()
        let needBlur = smooth > 0.001
        let needWhite = whitening > 0.001
        let lut = skinLutTexture
        lock.unlock()
        guard let applyPipeline = applyPipeline, let paramsBuffer = paramsBuffer else {
            return
        }
        guard needWhite == false || lut != nil else {
            DDLogError("skin LUT missing, skip beauty frame")
            return
        }
        
        let faces = landmarker?.copyLatestFaces() ?? []
        let face = faces.first
        if face == nil && !needWhite {
            return
        }
        var maskTexture: MTLTexture?
        if let face = face {
            if shouldRebuildMask(face: face) {
                _ = regionMask?.update(face: face)
            }
            maskTexture = regionMask?.texture
        }
        if maskTexture == nil {
            maskTexture = emptyMask
        }
        guard let maskTexture = maskTexture else {
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
        
        // 2. 全分辨率按遮罩合成；texture4 为当前美肤 LUT
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
        encoder.setTexture(lut ?? maskTexture, index: 4)
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

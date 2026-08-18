//
//  OFBeautyComputer.swift
//  LiveStreaming
//
//  美颜节点：磨皮、美白、亮眼、白牙。
//  磨皮对齐 BeautifyFaceDemo：半分辨率可分离双边 + Sobel 保边 + 肤色检测。
//  美白：脸区关键点采样当前肤色，全图按色度匹配皮肤（含脖子/手臂）；亮眼/白牙仍靠关键点遮罩。
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
    /// 与 Metal BeautyParams 对齐：四项强度 + 肤色 RGB + skinValid
    private var paramsBuffer: MTLBuffer?
    /// 当前档位强度
    private var smooth: Float = 0
    /// 美白强度 0…1
    private var whitening: Float = 0
    /// 亮眼强度 0…1
    private var brightEyes: Float = 0
    /// 白牙强度 0…1
    private var whiteTeeth: Float = 0
    /// 从脸颊/额区估出的肤色 R，给全图美白匹配用
    private var skinRefR: Float = 0.72
    /// 肤色 G
    private var skinRefG: Float = 0.55
    /// 肤色 B
    private var skinRefB: Float = 0.48
    /// 1 表示本趟采样有效；0 则 shader 只靠启发式肤色检测
    private var skinValid: Float = 0
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
        setupMetal()
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
    
    /// 调用方已持有 lock
    private func isIdentityLocked() -> Bool {
        return smooth < 0.001 && whitening < 0.001 && brightEyes < 0.001 && whiteTeeth < 0.001
    }
    
    /// 把 BeautyParams 写进已有 GPU buffer，避免每帧重新分配
    private func syncParamsBuffer() {
        let packed: [Float] = [smooth, whitening, brightEyes, whiteTeeth, skinRefR, skinRefG, skinRefB, skinValid]
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
    
    /// 鼻尖移动超过阈值，或隔了两帧，才重绘遮罩
    /// - Parameter face: 当前关键点
    /// - Returns: 是否需要栅格化
    private func shouldRebuildMask(face: [CGPoint]) -> Bool {
        framesSinceMask += 1
        let nose = face.count > 1 ? face[1] : .zero
        let dx = nose.x - lastNose.x
        let dy = nose.y - lastNose.y
        let moved = (dx * dx + dy * dy) > 0.000064
        if framesSinceMask >= 2 || moved || regionMask?.texture == nil {
            lastNose = nose
            framesSinceMask = 0
            return true
        }
        return false
    }
    
    /// 脸颊/鼻翼旁/眉心，避开唇眼，用来估当前肤色
    private static let skinSampleIndices = [50, 101, 116, 117, 187, 205, 280, 330, 346, 347, 411, 425, 151]
    
    /// 在人脸关键点邻域采样 BGRA，得到当前肤色中心。跟遮罩同频，避免每帧锁 buffer。
    /// - Parameters:
    ///   - face: 归一化关键点
    ///   - pixelBuffer: 当前帧，BGRA
    private func sampleFaceSkin(face: [CGPoint], pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 8, height > 8, face.count >= 426 else {
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var count: Float = 0
        for index in Self.skinSampleIndices {
            let px = Int((face[index].x * CGFloat(width)).rounded())
            let py = Int((face[index].y * CGFloat(height)).rounded())
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = min(max(px + dx, 0), width - 1)
                    let y = min(max(py + dy, 0), height - 1)
                    let offset = y * stride + x * 4
                    let b = Float(ptr[offset]) / 255.0
                    let g = Float(ptr[offset + 1]) / 255.0
                    let r = Float(ptr[offset + 2]) / 255.0
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // 1. 丢掉过暗过亮（阴影、高光、头发）
                    if luma < 0.14 || luma > 0.90 {
                        continue
                    }
                    // 2. 只要偏暖的像素，避免采到衣服/背景
                    if r + 0.02 < b || r + 0.03 < g {
                        continue
                    }
                    sumR += r
                    sumG += g
                    sumB += b
                    count += 1
                }
            }
        }
        guard count > 24 else {
            return
        }
        let meanR = sumR / count
        let meanG = sumG / count
        let meanB = sumB / count
        lock.lock()
        // 3. 指数平滑，灯光抖动时肤色中心不跳
        let alpha: Float = skinValid > 0.5 ? 0.28 : 1.0
        skinRefR = skinRefR * (1.0 - alpha) + meanR * alpha
        skinRefG = skinRefG * (1.0 - alpha) + meanG * alpha
        skinRefB = skinRefB * (1.0 - alpha) + meanB * alpha
        skinValid = 1
        syncParamsBuffer()
        lock.unlock()
    }
    
    /// 有人脸时按遮罩做磨皮/美白/亮眼/白牙
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    func process(_ frame: VideoFrame) {
        lock.lock()
        let needBlur = smooth > 0.001
        let needWhite = whitening > 0.001
        lock.unlock()
        guard let applyPipeline = applyPipeline, let paramsBuffer = paramsBuffer else {
            return
        }
        let faces = landmarker?.copyLatestFaces() ?? []
        guard let face = faces.first else {
            return
        }
        if shouldRebuildMask(face: face) {
            guard regionMask?.update(face: face) == true else {
                return
            }
            if needWhite {
                sampleFaceSkin(face: face, pixelBuffer: frame.pixelBuffer)
            }
        }
        guard let maskTexture = regionMask?.texture else {
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

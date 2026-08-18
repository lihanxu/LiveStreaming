//
//  OFFaceReshapeComputer.swift
//  LiveStreaming
//
//  面部重塑节点：瘦脸、大眼、瘦鼻、嘴巴、发际线、下颌。
//  在美颜着色之后做关键点局部 warp，遮罩仍对齐未变形的原图。
//

import Foundation
import Metal
import CocoaLumberjack

/// 处理图中的面部几何重塑滤镜。
class OFFaceReshapeComputer: NSObject, OFProcessNode {
    /// 共享 Metal 上下文
    private let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 输出缓冲池
    private let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// faceReshape compute pipeline
    private var pipelineState: MTLComputePipelineState?
    /// 与 kernel 对齐的 48 个 float：6 强度 + faceWidth + pad + 20 个 xy
    private var paramsBuffer: MTLBuffer?
    /// 瘦脸 −1…1，正瘦负胖
    private var slimFace: Float = 0
    /// 大眼 −1…1，正放大负缩小
    private var bigEye: Float = 0
    /// 瘦鼻 −1…1，正瘦负宽
    private var slimNose: Float = 0
    /// 嘴巴 −1…1，正放大负缩小
    private var mouth: Float = 0
    /// 发际线 −1…1，正上移负下移
    private var hairline: Float = 0
    /// 下颌 −1…1，正内收负外扩
    private var jaw: Float = 0
    /// 美颜总开关；关掉时不跑形变
    private var masterEnabled = false
    /// 按住对比时为 true，节点跳过但参数保留
    private var bypassed = false
    /// 保护档位，设置页与采集线程可能同时访问
    private let lock = NSLock()
    /// 人脸关键点来源
    weak var landmarker: OFFaceLandmarkerComputer?
    
    /// 总开关打开、有非零项、pipeline 就绪才跑
    var isEnabled: Bool {
        lock.lock()
        let on = masterEnabled && !isIdentityLocked() && !bypassed
        lock.unlock()
        return on && pipelineState != nil
    }
    
    /// 创建节点并编译 kernel
    override init() {
        super.init()
        setupMetal()
        syncParamsBuffer(packed: [Float](repeating: 0, count: 48))
    }
    
    /// 设置页改档位后调用
    /// - Parameter settings: 与磨皮等共用的美颜状态
    func applySettings(_ settings: OFBeautySettings) {
        lock.lock()
        masterEnabled = settings.isEnabled
        slimFace = OFBeautySettings.reshapeGpuStrength(settings.slimFace)
        bigEye = OFBeautySettings.reshapeGpuStrength(settings.bigEye)
        slimNose = OFBeautySettings.reshapeGpuStrength(settings.slimNose)
        mouth = OFBeautySettings.reshapeGpuStrength(settings.mouth)
        hairline = OFBeautySettings.reshapeGpuStrength(settings.hairline)
        jaw = OFBeautySettings.reshapeGpuStrength(settings.jaw)
        lock.unlock()
    }
    
    /// 对比原脸：不改参数，只决定这一帧是否跑 kernel
    /// - Parameter bypassed: true 时透传
    func setBypassed(_ bypassed: Bool) {
        lock.lock()
        self.bypassed = bypassed
        lock.unlock()
    }
    
    /// 编译 faceReshape kernel
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        guard let function = library?.makeFunction(name: "faceReshape") else {
            DDLogError("faceReshape kernel not found")
            return
        }
        do {
            pipelineState = try defalutMetal.device?.makeComputePipelineState(function: function)
            DDLogInfo("faceReshape pipeline ready")
        } catch {
            DDLogError("create faceReshape pipeline failed: \(error)")
        }
    }
    
    /// 调用方已持有 lock
    private func isIdentityLocked() -> Bool {
        return abs(slimFace) < 0.001
            && abs(bigEye) < 0.001
            && abs(slimNose) < 0.001
            && abs(mouth) < 0.001
            && abs(hairline) < 0.001
            && abs(jaw) < 0.001
    }
    
    /// 把控制点写入 GPU buffer
    /// - Parameter packed: 48 个 float
    private func syncParamsBuffer(packed: [Float]) {
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
    
    /// 两归一化点的各向同性距离，x 乘画面宽高比
    /// - Parameters:
    ///   - a: 点 A
    ///   - b: 点 B
    ///   - aspect: 宽/高
    /// - Returns: 距离
    private func isoDist(_ a: CGPoint, _ b: CGPoint, aspect: Float) -> Float {
        let dx = Float(a.x - b.x) * aspect
        let dy = Float(a.y - b.y)
        return hypot(dx, dy)
    }
    
    /// 按 468 点填 warp 参数。缺虹膜时用眼裂中点。
    /// - Parameters:
    ///   - face: 归一化关键点
    ///   - aspect: 画面宽高比
    /// - Returns: 48 个 float
    private func packParams(face: [CGPoint], aspect: Float) -> [Float] {
        func pt(_ index: Int) -> CGPoint {
            if index >= 0 && index < face.count {
                return face[index]
            }
            return .zero
        }
        let leftCheek = pt(234)
        let rightCheek = pt(454)
        let chin = pt(152)
        let forehead = pt(10)
        let nose = pt(1)
        let leftEye = face.count > 468 ? pt(468) : CGPoint(x: (pt(33).x + pt(133).x) * 0.5, y: (pt(33).y + pt(133).y) * 0.5)
        let rightEye = face.count > 473 ? pt(473) : CGPoint(x: (pt(263).x + pt(362).x) * 0.5, y: (pt(263).y + pt(362).y) * 0.5)
        let leftAla = pt(48)
        let rightAla = pt(278)
        let mouthCenter = CGPoint(x: (pt(13).x + pt(14).x) * 0.5, y: (pt(13).y + pt(14).y) * 0.5)
        let leftMouth = pt(61)
        let rightMouth = pt(291)
        let leftJaw = pt(172)
        let rightJaw = pt(397)
        let leftCheek2 = pt(132)
        let rightCheek2 = pt(361)
        let leftJaw2 = pt(150)
        let rightJaw2 = pt(379)
        let faceCenter = CGPoint(x: (leftCheek.x + rightCheek.x) * 0.5, y: nose.y)
        let faceW = max(isoDist(leftCheek, rightCheek, aspect: aspect), 0.08)
        let faceH = max(isoDist(chin, forehead, aspect: aspect), 0.08)
        let upX = Float(forehead.x - chin.x)
        let upY = Float(forehead.y - chin.y)
        let upLen = max(hypot(upX, upY), 1e-4)
        let extra = faceH * 0.14
        let hairTarget = CGPoint(
            x: forehead.x + CGFloat(upX / upLen) * CGFloat(extra),
            y: forehead.y + CGFloat(upY / upLen) * CGFloat(extra)
        )
        lock.lock()
        let packed: [Float] = [
            slimFace, bigEye, slimNose, mouth, hairline, jaw, faceW, 0,
            Float(faceCenter.x), Float(faceCenter.y),
            Float(chin.x), Float(chin.y),
            Float(forehead.x), Float(forehead.y),
            Float(leftCheek.x), Float(leftCheek.y),
            Float(rightCheek.x), Float(rightCheek.y),
            Float(leftEye.x), Float(leftEye.y),
            Float(rightEye.x), Float(rightEye.y),
            Float(leftAla.x), Float(leftAla.y),
            Float(rightAla.x), Float(rightAla.y),
            Float(mouthCenter.x), Float(mouthCenter.y),
            Float(leftMouth.x), Float(leftMouth.y),
            Float(rightMouth.x), Float(rightMouth.y),
            Float(leftJaw.x), Float(leftJaw.y),
            Float(rightJaw.x), Float(rightJaw.y),
            Float(forehead.x), Float(forehead.y),
            Float(hairTarget.x), Float(hairTarget.y),
            Float(leftCheek2.x), Float(leftCheek2.y),
            Float(rightCheek2.x), Float(rightCheek2.y),
            Float(leftJaw2.x), Float(leftJaw2.y),
            Float(rightJaw2.x), Float(rightJaw2.y)
        ]
        lock.unlock()
        return packed
    }
    
    /// 有人脸且档位非零时按关键点 warp
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    func process(_ frame: VideoFrame) {
        guard let pipelineState = pipelineState else {
            return
        }
        let faces = landmarker?.copyLatestFaces() ?? []
        guard let face = faces.first, face.count >= 468 else {
            return
        }
        let aspect = Float(frame.frameWidth) / max(Float(frame.frameHeight), 1)
        let packed = packParams(face: face, aspect: aspect)
        syncParamsBuffer(packed: packed)
        guard let paramsBuffer = paramsBuffer else {
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
        guard let outPixelBuffer = pixelBufferPool.createPixelBuffer(),
              let outPair = createTextureFromPixelBuffer(pixelBuffer: outPixelBuffer),
              let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            return
        }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outPair.1, index: 1)
        encoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            DDLogError("faceReshape status:\(commandBuffer.status.rawValue)")
            return
        }
        frame.pixelBuffer = outPixelBuffer
        frame.texture = outPair.1
        _ = sourcePair
        _ = outPair
    }
}

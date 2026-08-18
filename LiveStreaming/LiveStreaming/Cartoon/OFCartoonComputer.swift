//
//  OFCartoonComputer.swift
//  LiveStreaming
//
//  漫画风节点：AnimeGANv3 只吃 512 正方形。
//  风景模型会把脸涂成色块，所以推理保持宽高比（边缘外扩填充），
//  合成时脸上少用风格、贴回原图亮度和高频，减轻结块。
//

import Foundation
import CoreML
import Vision
import CoreImage
import Metal
import CocoaLumberjack

/// 漫画风预设。fileName 为 nil 表示关闭。
struct OFCartoonPreset {
    /// 设置页显示名
    let displayName: String
    /// Bundle 中的 mlmodel 名（不含扩展名）；关闭时为 nil
    let fileName: String?
    
    /// 内置预设，第一项为关闭
    static let all: [OFCartoonPreset] = [
        OFCartoonPreset(displayName: "关", fileName: nil),
        OFCartoonPreset(displayName: "宫崎骏", fileName: "AnimeGANv3_Hayao_36"),
        OFCartoonPreset(displayName: "新海诚", fileName: "AnimeGANv3_Shinkai_37"),
    ]
}

/// 处理图中的整帧漫画风节点。
class OFCartoonComputer: NSObject, OFProcessNode {
    /// AnimeGANv3 固定输入边长
    private let modelSize = 512
    /// 共享 Metal 设备
    private let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 全分辨率输出池
    private let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// 拼 512 正方形、再拉回原尺寸
    private var ciContext: CIContext?
    /// 当前 Vision 包装
    private var visionModel: VNCoreMLModel?
    /// 复用的 Core ML 请求
    private var visionRequest: VNCoreMLRequest?
    /// 合成 kernel：原图 + 风格图 + 脸遮罩
    private var compositePipeline: MTLComputePipelineState?
    /// 背景风格 / 脸风格 / 细节 / 亮度贴回
    private var paramsBuffer: MTLBuffer?
    /// 512×512 模型输入（保比例 letterbox）
    private var modelInputBuffer: CVPixelBuffer?
    /// 无人脸时绑一张全 0 遮罩，shader 不必分两套
    private var emptyMaskTexture: MTLTexture?
    /// 人脸区域遮罩（R=皮肤）
    private var regionMask: OFFaceRegionMask?
    /// 距上次重绘遮罩的帧数
    private var framesSinceMask = 100
    /// 鼻尖，用来判断脸是否明显移动
    private var lastNose = CGPoint.zero
    /// 当前预设下标
    private var presetIndex = 0
    /// 保护预设切换与采集线程
    private let lock = NSLock()
    /// 避免每帧打 Info
    private var didLogProcessInfo = false
    /// 人脸关键点；漫画风打开时由门面打开推理
    weak var landmarker: OFFaceLandmarkerComputer?
    
    /// 当前选中的预设
    var currentPreset: OFCartoonPreset {
        lock.lock()
        let preset = OFCartoonPreset.all[presetIndex]
        lock.unlock()
        return preset
    }
    
    /// 当前预设下标，供设置页高亮
    var currentPresetIndex: Int {
        lock.lock()
        let index = presetIndex
        lock.unlock()
        return index
    }
    
    /// 选了模型且 Vision、合成 pipeline 都就绪才跑
    var isEnabled: Bool {
        lock.lock()
        let ready = OFCartoonPreset.all[presetIndex].fileName != nil && visionRequest != nil && compositePipeline != nil
        lock.unlock()
        return ready
    }
    
    /// 创建 CI / Metal / 空遮罩；默认关闭，不预加载模型
    override init() {
        super.init()
        if let device = defalutMetal.device {
            ciContext = CIContext(mtlDevice: device)
        } else {
            ciContext = CIContext()
        }
        regionMask = OFFaceRegionMask(device: defalutMetal.device)
        setupCompositePipeline()
        setupEmptyMask()
        setupParamsBuffer()
    }
    
    /// 编译 cartoonComposite，并把合成参数写进 GPU buffer
    private func setupCompositePipeline() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        guard let program = library?.makeFunction(name: "cartoonComposite") else {
            DDLogError("cartoonComposite kernel not found")
            return
        }
        do {
            compositePipeline = try defalutMetal.device?.makeComputePipelineState(function: program)
        } catch {
            DDLogError("create cartoonComposite pipeline failed: \(error)")
        }
    }
    
    /// 背景 0.76、脸 0.32、细节 0.68、脸上亮度贴回 0.72；风景 GAN 不能 100% 盖脸
    private func setupParamsBuffer() {
        let params: [Float] = [0.76, 0.32, 0.68, 0.72]
        paramsBuffer = defalutMetal.device?.makeBuffer(bytes: params, length: MemoryLayout<Float>.size * params.count, options: [])
    }
    
    /// 1×1 黑色遮罩，没有检测到脸时整帧走「背景」混合
    private func setupEmptyMask() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        emptyMaskTexture = defalutMetal.device?.makeTexture(descriptor: desc)
        var pixel: [UInt8] = [0, 0, 0, 255]
        emptyMaskTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }
    
    /// 分配（或复用）一块 Metal 兼容的 BGRA buffer
    /// - Parameters:
    ///   - width: 宽
    ///   - height: 高
    ///   - existing: 已有 buffer，尺寸对则复用
    /// - Returns: 可写 CVPixelBuffer
    private func makeBGRABuffer(width: Int, height: Int, existing: CVPixelBuffer?) -> CVPixelBuffer? {
        if let existing = existing,
           CVPixelBufferGetWidth(existing) == width,
           CVPixelBufferGetHeight(existing) == height {
            return existing
        }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        if status != kCVReturnSuccess {
            DDLogError("cartoon BGRA buffer create failed \(width)x\(height) status:\(status)")
            return nil
        }
        return buffer
    }
    
    /// 直接选中某个预设并加载对应 Core ML
    /// - Parameter index: `OFCartoonPreset.all` 下标，越界则忽略
    func applyPreset(at index: Int) {
        guard OFCartoonPreset.all.indices.contains(index) else {
            return
        }
        lock.lock()
        presetIndex = index
        loadCurrentModelLocked()
        didLogProcessInfo = false
        let name = OFCartoonPreset.all[presetIndex].displayName
        let enabled = visionRequest != nil
        lock.unlock()
        DDLogInfo("apply cartoon \(name), enabled:\(enabled)")
    }
    
    /// 在 lock 内按当前预设加载或清空模型
    private func loadCurrentModelLocked() {
        visionModel = nil
        visionRequest = nil
        guard let fileName = OFCartoonPreset.all[presetIndex].fileName else {
            DDLogInfo("cartoon disabled")
            return
        }
        guard let modelURL = locateModel(named: fileName) else {
            DDLogError("cartoon model not found: \(fileName)")
            return
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            // 输入已是 512 正方形，scaleFill 不再拉伸人脸
            request.imageCropAndScaleOption = .scaleFill
            visionModel = vnModel
            visionRequest = request
            DDLogInfo("cartoon model loaded: \(fileName)")
        } catch {
            DDLogError("cartoon model load failed \(fileName): \(error)")
        }
    }
    
    /// 优先用 Xcode 编好的 mlmodelc；没有则退回原始 mlmodel
    /// - Parameter named: 不含扩展名的资源名
    /// - Returns: 可被 MLModel 打开的 URL
    private func locateModel(named: String) -> URL? {
        if let compiled = Bundle.main.url(forResource: named, withExtension: "mlmodelc") {
            return compiled
        }
        guard let raw = Bundle.main.url(forResource: named, withExtension: "mlmodel") else {
            return nil
        }
        do {
            return try MLModel.compileModel(at: raw)
        } catch {
            DDLogError("compile cartoon mlmodel failed: \(error)")
            return nil
        }
    }
    
    /// 按宽高比缩进 512 正方形，四周用边缘像素外扩，避免黑边污染 GAN
    /// - Parameter image: 原帧 CIImage
    /// - Returns: 正方形图 + 内容区（CI 坐标，原点左下）
    private func letterbox(_ image: CIImage) -> (square: CIImage, content: CGRect) {
        let extent = image.extent
        let scale = min(CGFloat(modelSize) / max(extent.width, 1), CGFloat(modelSize) / max(extent.height, 1))
        let contentWidth = extent.width * scale
        let contentHeight = extent.height * scale
        let originX = (CGFloat(modelSize) - contentWidth) * 0.5
        let originY = (CGFloat(modelSize) - contentHeight) * 0.5
        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        scaled = scaled.transformed(by: CGAffineTransform(translationX: originX - scaled.extent.origin.x, y: originY - scaled.extent.origin.y))
        let square = scaled.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: modelSize, height: modelSize))
        return (square, CGRect(x: originX, y: originY, width: contentWidth, height: contentHeight))
    }
    
    /// 从 512 输出裁掉填充区，Lanczos 拉回采集分辨率
    /// - Parameters:
    ///   - square: 模型输出
    ///   - content: letterbox 时的内容矩形
    ///   - targetWidth: 原帧宽
    ///   - targetHeight: 原帧高
    /// - Returns: 与原帧同尺寸的风格图
    private func unletterbox(_ square: CIImage, content: CGRect, targetWidth: CGFloat, targetHeight: CGFloat) -> CIImage {
        var cropped = square.cropped(to: content)
        cropped = cropped.transformed(by: CGAffineTransform(translationX: -content.origin.x, y: -content.origin.y))
        let sx = targetWidth / max(content.width, 1)
        let sy = targetHeight / max(content.height, 1)
        var scaled = cropped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        scaled = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
        return scaled
    }
    
    /// 从 CVPixelBuffer 包一层 Metal 纹理
    /// - Parameter pixelBuffer: BGRA 像素缓冲
    /// - Returns: (CV 包装, MTLTexture)
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let textureCache = defalutMetal.videoTextureCache else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            DDLogError("create cartoon metal texture failed, status: \(status)")
            return nil
        }
        return (cvTexture, texture)
    }
    
    /// 脸动了或隔帧才重画遮罩，和美颜节点同一套阈值
    /// - Parameter face: 归一化关键点
    /// - Returns: 是否需要 update mask
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
    
    /// letterbox → AnimeGAN → 拉回原尺寸 → 脸上少风格并补细节
    /// - Parameter frame: 原地替换 pixelBuffer 与 texture
    func process(_ frame: VideoFrame) {
        lock.lock()
        let request = visionRequest
        lock.unlock()
        guard let request = request,
              let ciContext = ciContext,
              let compositePipeline = compositePipeline,
              let paramsBuffer = paramsBuffer else {
            return
        }
        
        // 1. 保比例铺进 512，再送给模型，避免把脸压扁
        guard let inputBuffer = makeBGRABuffer(width: modelSize, height: modelSize, existing: modelInputBuffer) else {
            return
        }
        modelInputBuffer = inputBuffer
        let originalCI = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let boxed = letterbox(originalCI)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(boxed.square, to: inputBuffer, bounds: CGRect(x: 0, y: 0, width: modelSize, height: modelSize), colorSpace: colorSpace)
        
        let handler = VNImageRequestHandler(cvPixelBuffer: inputBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DDLogError("cartoon vision perform failed: \(error)")
            return
        }
        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            if !didLogProcessInfo {
                DDLogError("cartoon output is not a pixel buffer")
            }
            return
        }
        
        // 2. 裁掉填充并放大到采集分辨率
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        guard let cartoonPixelBuffer = pixelBufferPool.createPixelBuffer(),
              let destPixelBuffer = pixelBufferPool.createPixelBuffer() else {
            DDLogError("cartoon dest pixel buffer create failed")
            return
        }
        let restored = unletterbox(
            CIImage(cvPixelBuffer: observation.pixelBuffer),
            content: boxed.content,
            targetWidth: CGFloat(frame.frameWidth),
            targetHeight: CGFloat(frame.frameHeight)
        )
        ciContext.render(
            restored,
            to: cartoonPixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: frame.frameWidth, height: frame.frameHeight),
            colorSpace: colorSpace
        )
        
        // 3. 有人脸则更新皮肤遮罩，合成时脸上少用 GAN
        var maskTexture = emptyMaskTexture
        if let face = landmarker?.copyLatestFaces().first {
            if shouldRebuildMask(face: face) {
                _ = regionMask?.update(face: face)
            }
            maskTexture = regionMask?.texture ?? emptyMaskTexture
        }
        guard let maskTexture = maskTexture else {
            return
        }
        
        let sourcePair: (CVMetalTexture, MTLTexture)?
        if frame.texture != nil {
            sourcePair = nil
        } else {
            sourcePair = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        }
        guard let sourceTexture = sourcePair?.1 ?? frame.texture,
              let cartoonPair = createTextureFromPixelBuffer(pixelBuffer: cartoonPixelBuffer),
              let destPair = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer),
              let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            return
        }
        
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(cartoonPair.1, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        encoder.setTexture(destPair.1, index: 3)
        encoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            DDLogError("cartoon composite status:\(commandBuffer.status.rawValue)")
            return
        }
        
        if !didLogProcessInfo {
            DDLogInfo("cartoon process frame:\(frame.frameWidth)x\(frame.frameHeight) letterbox:512")
            didLogProcessInfo = true
        }
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = destPair.1
        _ = sourcePair
        _ = cartoonPair
        _ = destPair
    }
}

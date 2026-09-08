//
//  OFLUTComputer.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  LUT 处理节点：把 512×512 PNG 色表做成 Metal 纹理，对视频做四面体插值。
//  关闭（预设 fileName 为 nil）时 isEnabled 为 false，图调度器会跳过本节点。
//

import Foundation
import Metal
import CocoaLumberjack

/// LUT 预设。fileName 为 nil 表示关闭调色。
public struct OFLUTPreset {
    /// 按钮上显示的短名
    public let displayName: String
    /// Bundle 中的 PNG 名（不含扩展名）
    public let fileName: String?
    
    /// 内置预设列表，第一项为关闭；fileName 与 Resource/LUT 下 PNG 名一致（不含扩展名）
    public static let all: [OFLUTPreset] = [
        OFLUTPreset(displayName: "LUT", fileName: nil),
        OFLUTPreset(displayName: "暖色", fileName: "Warm"),
        OFLUTPreset(displayName: "柔和", fileName: "Soft"),
        OFLUTPreset(displayName: "人像", fileName: "Portrait"),
        OFLUTPreset(displayName: "电影", fileName: "ProMovie"),
        OFLUTPreset(displayName: "复古", fileName: "Vintage"),
        OFLUTPreset(displayName: "都市", fileName: "Urban"),
        OFLUTPreset(displayName: "夜景", fileName: "Night"),
        OFLUTPreset(displayName: "海洋", fileName: "Ocean"),
        OFLUTPreset(displayName: "青橙", fileName: "TealOrange"),
        OFLUTPreset(displayName: "黑白", fileName: "Monochrome"),
        OFLUTPreset(displayName: "负片", fileName: "NegativeClassic"),
    ]
}

/// 处理图中的 LUT 节点。
public class OFLUTComputer: NSObject, OFProcessNode {
    /// 本实例 Metal 设备 / 队列 / sizeBuffer
    private let defalutMetal: OFDefalutMetal
    /// 本实例滤镜输出像素缓冲池
    private let pixelBufferPool: OFPixelBufferTool
    /// ColorLUT compute pipeline
    private var pipelineState: MTLComputePipelineState?
    /// 当前色表纹理，关闭 LUT 时为 nil
    private var lutTexture: MTLTexture?
    /// 当前预设在 `OFLUTPreset.all` 中的下标
    private var presetIndex = 0
    /// LUT 与原图混合，0 关闭效果 1 全强度
    private var intensity: Float = 1
    /// GPU 强度 buffer，避免每帧分配
    private var intensityBuffer: MTLBuffer?
    /// 按住对比时跳过
    private var bypassed = false
    /// 避免每帧打 Info 日志
    private var didLogProcessInfo = false
    
    /// 当前选中的预设
    public var currentPreset: OFLUTPreset {
        return OFLUTPreset.all[presetIndex]
    }
    
    /// 选了色表、有强度、纹理和 pipeline 都就绪才真正跑 GPU
    public var isEnabled: Bool {
        return !bypassed
            && currentPreset.fileName != nil
            && intensity > 0.001
            && lutTexture != nil
            && pipelineState != nil
    }
    
    /// 创建节点并编译 ColorLUT kernel
    /// - Parameter context: 门面注入的 GPU 资源
    public init(context: OFFilterContext) {
        self.defalutMetal = context.metal
        self.pixelBufferPool = context.pixelBufferPool
        super.init()
        setupMetal()
        syncIntensityBuffer()
    }
    
    /// 从默认 library 取出 ColorLUT 并创建 compute pipeline
    private func setupMetal() {
        let library = defalutMetal.makeShaderLibrary()
        guard let program = library?.makeFunction(name: "ColorLUT") else {
            DDLogError("ColorLUT kernel not found")
            return
        }
        do {
            pipelineState = try defalutMetal.device?.makeComputePipelineState(function: program)
            DDLogInfo("ColorLUT pipeline ready")
        } catch {
            DDLogError("create ColorLUT pipeline failed: \(error)")
        }
    }
    
    /// 循环切换预设并加载对应 PNG 纹理
    /// - Returns: 切换后的预设
    @discardableResult
    public func switchToNext() -> OFLUTPreset {
        presetIndex = (presetIndex + 1) % OFLUTPreset.all.count
        loadCurrentLUT()
        didLogProcessInfo = false
        DDLogInfo("switch LUT to \(currentPreset.displayName), enabled:\(isEnabled)")
        return currentPreset
    }
    
    /// 直接选中某个预设（设置二级页用）
    /// - Parameter index: `OFLUTPreset.all` 下标，越界则忽略
    public func applyPreset(at index: Int) {
        guard OFLUTPreset.all.indices.contains(index) else {
            return
        }
        presetIndex = index
        loadCurrentLUT()
        didLogProcessInfo = false
        DDLogInfo("apply LUT \(currentPreset.displayName), enabled:\(isEnabled)")
    }
    
    /// 当前预设下标，供设置页高亮「已选」
    public var currentPresetIndex: Int {
        return presetIndex
    }
    
    /// 灵敏度 0…100，给设置页滑杆
    public var intensitySlider: Float {
        return intensity * 100
    }
    
    /// 写入灵敏度
    /// - Parameter slider: 0…100
    public func setIntensitySlider(_ slider: Float) {
        intensity = min(1, max(0, slider / 100))
        syncIntensityBuffer()
    }
    
    /// 按住对比：不改预设，只决定这一帧是否跑 kernel
    /// - Parameter bypassed: true 时透传
    public func setBypassed(_ bypassed: Bool) {
        self.bypassed = bypassed
    }
    
    /// 把强度写进 GPU buffer
    private func syncIntensityBuffer() {
        let byteCount = MemoryLayout<Float>.size
        if intensityBuffer == nil || (intensityBuffer?.length ?? 0) < byteCount {
            intensityBuffer = defalutMetal.device?.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        intensityBuffer?.contents().storeBytes(of: intensity, as: Float.self)
    }
    
    /// 按当前预设加载或清空 lutTexture
    private func loadCurrentLUT() {
        lutTexture = nil
        guard let fileName = currentPreset.fileName, let device = defalutMetal.device else {
            DDLogInfo("LUT disabled")
            return
        }
        lutTexture = OFLUTLoader.loadTexture(named: fileName, device: device)
        if let lutTexture = lutTexture {
            DDLogInfo("LUT texture loaded: \(fileName) \(lutTexture.width)x\(lutTexture.height) format:\(lutTexture.pixelFormat.rawValue)")
        } else {
            DDLogError("LUT texture load failed: \(fileName)")
        }
    }
    
    /// 从 CVPixelBuffer 包一层 Metal 纹理
    /// 必须同时保留 CVMetalTexture，否则底层 IOSurface 可能在 GPU 完成前被释放
    /// - Parameter pixelBuffer: BGRA 像素缓冲
    /// - Returns: (CV 包装, MTLTexture)；失败为 nil
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let textureCache = defalutMetal.videoTextureCache else {
            DDLogError("metal texture cache is nil")
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
            DDLogError("create LUT metal texture failed, status: \(status) size:\(width)x\(height)")
            return nil
        }
        return (cvTexture, texture)
    }
    
    /// 对当前帧做 ColorLUT：源纹理 + LUT 纹理 → 新的 BGRA pixel buffer
    /// - Parameter frame: 会被原地替换 pixelBuffer 与 texture
    public func process(_ frame: VideoFrame) {
        guard isEnabled, let pipelineState = pipelineState, let lutTexture = lutTexture, let intensityBuffer = intensityBuffer else {
            return
        }
        // 1. 按帧尺寸更新线程组和输出池
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        
        // 2. 准备源纹理：优先复用上游 Metal 纹理
        let sourcePair: (CVMetalTexture, MTLTexture)?
        if let existing = frame.texture {
            sourcePair = nil
            if !didLogProcessInfo {
                DDLogInfo("LUT source uses existing metal texture \(existing.width)x\(existing.height)")
            }
        } else {
            sourcePair = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        }
        let sourceTexture = sourcePair?.1 ?? frame.texture
        guard let sourceTexture = sourceTexture else {
            DDLogError("LUT source texture is nil, skip")
            return
        }
        
        // 3. 从池里取一块目标 buffer 并包成可写纹理
        guard let destPixelBuffer = pixelBufferPool.createPixelBuffer() else {
            DDLogError("LUT dest pixel buffer create failed")
            return
        }
        guard let destPair = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer) else {
            return
        }
        
        guard let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            DDLogError("LUT metal command encoder create failed")
            return
        }
        
        if !didLogProcessInfo {
            DDLogInfo("LUT process frame:\(frame.frameWidth)x\(frame.frameHeight) lut:\(lutTexture.width)x\(lutTexture.height) groups:\(threadgroups.width)x\(threadgroups.height)")
            didLogProcessInfo = true
        }
        
        // 4. 绑定纹理：0 视频、1 LUT、2 输出；buffer0 为宽高
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(sourceTexture, index: 0)
        computeEncoder.setTexture(lutTexture, index: 1)
        computeEncoder.setTexture(destPair.1, index: 2)
        computeEncoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(intensityBuffer, offset: 0, index: 1)
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if commandBuffer.status != .completed {
            DDLogError("LUT compute status:\(commandBuffer.status.rawValue) error:\(String(describing: commandBuffer.error))")
            return
        }
        
        // 5. 把结果写回帧，供预览和后续节点使用
        frame.pixelBuffer = destPixelBuffer
        frame.texture = destPair.1
        // 延长 CVMetalTexture 生命周期，覆盖 waitUntilCompleted 之前的 GPU 使用
        _ = sourcePair
        _ = destPair
    }
}

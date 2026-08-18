//
//  OFLUTComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  LUT 处理节点：把 512×512 PNG 色表做成 Metal 纹理，对视频做四面体插值。
//  关闭（预设 fileName 为 nil）时 isEnabled 为 false，图调度器会跳过本节点。
//

import Foundation
import Metal
import CocoaLumberjack

/// LUT 预设。fileName 为 nil 表示关闭调色。
struct OFLUTPreset {
    /// 按钮上显示的短名
    let displayName: String
    /// Bundle 中的 PNG 名（不含扩展名）
    let fileName: String?
    
    /// 内置预设列表，第一项为关闭
    static let all: [OFLUTPreset] = [
        OFLUTPreset(displayName: "LUT", fileName: nil),
        OFLUTPreset(displayName: "neutral", fileName: "neutral-lut"),
        OFLUTPreset(displayName: "Rec709", fileName: "Rec709 normal"),
        OFLUTPreset(displayName: "sRGB", fileName: "SRGB normal"),
        OFLUTPreset(displayName: "ACES", fileName: "ACESAP0 normal"),
    ]
}

/// 处理图中的 LUT 节点。
class OFLUTComputer: NSObject, OFProcessNode {
    /// 共享 Metal 设备 / 队列 / sizeBuffer
    private let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 滤镜输出像素缓冲池
    private let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// ColorLUT compute pipeline
    private var pipelineState: MTLComputePipelineState?
    /// 当前色表纹理，关闭 LUT 时为 nil
    private var lutTexture: MTLTexture?
    /// 当前预设在 `OFLUTPreset.all` 中的下标
    private var presetIndex = 0
    /// 避免每帧打 Info 日志
    private var didLogProcessInfo = false
    
    /// 当前选中的预设
    var currentPreset: OFLUTPreset {
        return OFLUTPreset.all[presetIndex]
    }
    
    /// 选了色表、纹理和 pipeline 都就绪才真正跑 GPU
    var isEnabled: Bool {
        return currentPreset.fileName != nil && lutTexture != nil && pipelineState != nil
    }
    
    /// 创建节点并编译 ColorLUT kernel
    override init() {
        super.init()
        setupMetal()
    }
    
    /// 从默认 library 取出 ColorLUT 并创建 compute pipeline
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
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
    func switchToNext() -> OFLUTPreset {
        presetIndex = (presetIndex + 1) % OFLUTPreset.all.count
        loadCurrentLUT()
        didLogProcessInfo = false
        DDLogInfo("switch LUT to \(currentPreset.displayName), enabled:\(isEnabled)")
        return currentPreset
    }
    
    /// 直接选中某个预设（设置二级页用）
    /// - Parameter index: `OFLUTPreset.all` 下标，越界则忽略
    func applyPreset(at index: Int) {
        guard OFLUTPreset.all.indices.contains(index) else {
            return
        }
        presetIndex = index
        loadCurrentLUT()
        didLogProcessInfo = false
        DDLogInfo("apply LUT \(currentPreset.displayName), enabled:\(isEnabled)")
    }
    
    /// 当前预设下标，供设置页高亮「已选」
    var currentPresetIndex: Int {
        return presetIndex
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
    func process(_ frame: VideoFrame) {
        guard isEnabled, let pipelineState = pipelineState, let lutTexture = lutTexture else {
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

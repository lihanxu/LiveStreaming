//
//  OFTransitionComputer.swift
//  LiveStreaming
//
//  场景转场节点：冻结上一画面，再与当前直播帧按模版混合。
//  选中模版后立刻预览一次；切摄像头时若已选模版也会自动播放。
//  关闭时 isEnabled 为 false，图调度器跳过。
//

import Foundation
import Metal
import QuartzCore
import CocoaLumberjack

/// 内置转场模版。rawValue 写入 GPU type。
public enum OFTransitionStyle: Int {
    /// 关闭，不播放
    case none = 0
    /// 交叉淡化
    case fade = 1
    /// 从左往右擦除露出新画面
    case wipeLeft = 2
    /// 从右往左擦除
    case wipeRight = 3
    /// 从上往下擦除
    case wipeUp = 4
    /// 从下往上擦除
    case wipeDown = 5
    /// 圆心向外展开
    case iris = 6
    /// 中间最糊的溶解
    case blur = 7
    /// 过曝闪光后切到新画面
    case flash = 8
    /// 旧画面放大淡出，新画面推近
    case zoom = 9
    /// 旧画面被推向右侧
    case slideLeft = 10
}

/// 设置页上的一项转场预设。
public struct OFTransitionPreset {
    /// 格子 / 选项标题
    public let displayName: String
    /// 对应 GPU 模版；nil 表示关
    public let style: OFTransitionStyle?
    
    /// 内置列表，第一项为关闭
    public static let all: [OFTransitionPreset] = [
        OFTransitionPreset(displayName: "关", style: nil),
        OFTransitionPreset(displayName: "淡化", style: .fade),
        OFTransitionPreset(displayName: "左擦", style: .wipeLeft),
        OFTransitionPreset(displayName: "右擦", style: .wipeRight),
        OFTransitionPreset(displayName: "上擦", style: .wipeUp),
        OFTransitionPreset(displayName: "下擦", style: .wipeDown),
        OFTransitionPreset(displayName: "圆形", style: .iris),
        OFTransitionPreset(displayName: "模糊", style: .blur),
        OFTransitionPreset(displayName: "闪光", style: .flash),
        OFTransitionPreset(displayName: "推近", style: .zoom),
        OFTransitionPreset(displayName: "左推", style: .slideLeft),
    ]
}

/// 处理图中的转场节点，挂在 Peak 之后、Sink 之前。
public class OFTransitionComputer: NSObject, OFProcessNode {
    /// 本实例 Metal 上下文
    private let defalutMetal: OFDefalutMetal
    /// 本实例输出缓冲池
    private let pixelBufferPool: OFPixelBufferTool
    /// 转场混合 kernel
    private var mixPipeline: MTLComputePipelineState?
    /// 把当前帧拷进冻结纹理
    private var copyPipeline: MTLComputePipelineState?
    /// 冻结的「从」画面，生命周期跨多帧
    private var fromTexture: MTLTexture?
    /// 当前预设下标
    private var presetIndex = 0
    /// 时长滑杆 0…100，映射到 0.3…2.0 秒
    private var durationSlider: Float = 50
    /// 下一帧先冻结再开始计时
    private var pendingCapture = false
    /// 正在播进度
    private var playing = false
    /// 冻结完成时刻，单位秒
    private var startTime: CFTimeInterval = 0
    /// 保护预设 / 播放状态；设置页与采集线程可能同时访问
    private let stateLock = NSLock()
    
    /// 当前选中的预设
    public var currentPreset: OFTransitionPreset {
        return OFTransitionPreset.all[presetIndex]
    }
    
    /// 当前预设下标，供设置页高亮
    public var currentPresetIndex: Int {
        return presetIndex
    }
    
    /// 时长滑杆当前值
    public var durationSliderValue: Float {
        stateLock.lock()
        let value = durationSlider
        stateLock.unlock()
        return value
    }
    
    /// 有冻结请求或正在播放才进 GPU
    public var isEnabled: Bool {
        stateLock.lock()
        let active = pendingCapture || playing
        stateLock.unlock()
        return active && mixPipeline != nil && copyPipeline != nil
    }
    
    /// 创建节点并编译 kernel
    /// - Parameter context: 门面注入的 GPU 资源
    public init(context: OFFilterContext) {
        self.defalutMetal = context.metal
        self.pixelBufferPool = context.pixelBufferPool
        super.init()
        setupMetal()
    }
    
    /// 选中预设；非「关」则立刻预览一次
    /// - Parameter index: `OFTransitionPreset.all` 下标
    public func applyPreset(at index: Int) {
        guard OFTransitionPreset.all.indices.contains(index) else {
            return
        }
        stateLock.lock()
        presetIndex = index
        if currentPreset.style == nil {
            pendingCapture = false
            playing = false
        } else {
            pendingCapture = true
            playing = false
        }
        stateLock.unlock()
        DDLogInfo("apply transition \(currentPreset.displayName)")
    }
    
    /// 已选模版时在切摄像头前调用，用下一帧作「从」
    public func playIfArmed() {
        stateLock.lock()
        let armed = currentPreset.style != nil
        if armed {
            pendingCapture = true
            playing = false
        }
        stateLock.unlock()
        if armed {
            DDLogInfo("arm transition \(currentPreset.displayName) for camera switch")
        }
    }
    
    /// 写入时长滑杆
    /// - Parameter value: 0…100
    public func setDurationSlider(_ value: Float) {
        stateLock.lock()
        durationSlider = min(100, max(0, value))
        stateLock.unlock()
    }
    
    /// 时长滑杆拉回默认 50（约 1.15 秒）
    public func resetDurationSlider() {
        setDurationSlider(50)
    }
    
    /// 编译 copyTexture2D / sceneTransition
    private func setupMetal() {
        let library = defalutMetal.makeShaderLibrary()
        guard let copyFn = library?.makeFunction(name: "copyTexture2D"),
              let mixFn = library?.makeFunction(name: "sceneTransition") else {
            DDLogError("transition kernels not found")
            return
        }
        do {
            copyPipeline = try defalutMetal.device?.makeComputePipelineState(function: copyFn)
            mixPipeline = try defalutMetal.device?.makeComputePipelineState(function: mixFn)
            DDLogInfo("transition pipelines ready")
        } catch {
            DDLogError("create transition pipeline failed: \(error)")
        }
    }
    
    /// 滑杆映射成秒；0 也至少 0.3s，避免一帧闪过看不出模版
    /// - Parameter slider: 0…100
    /// - Returns: 播放时长
    private func durationSeconds(from slider: Float) -> CFTimeInterval {
        return CFTimeInterval(0.3 + min(100, max(0, slider)) / 100 * 1.7)
    }
    
    /// 按帧尺寸准备可读写的冻结纹理
    /// - Parameters:
    ///   - width: 宽
    ///   - height: 高
    /// - Returns: 可 shaderRead/Write 的私有纹理
    private func ensureFromTexture(width: Int, height: Int) -> MTLTexture? {
        if let fromTexture = fromTexture, fromTexture.width == width, fromTexture.height == height {
            return fromTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        fromTexture = defalutMetal.device?.makeTexture(descriptor: descriptor)
        return fromTexture
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
            DDLogError("transition texture wrap failed, status:\(status)")
            return nil
        }
        return (cvTexture, texture)
    }
    
    /// 冻结当前帧，或按进度把冻结帧与直播帧混合
    /// - Parameter frame: 原地替换 pixelBuffer / texture
    public func process(_ frame: VideoFrame) {
        stateLock.lock()
        let capture = pendingCapture
        let isPlaying = playing
        let style = currentPreset.style
        let slider = durationSlider
        stateLock.unlock()
        
        guard let style = style, let copyPipeline = copyPipeline, let mixPipeline = mixPipeline else {
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
        guard let sourceTexture = sourcePair?.1 ?? frame.texture,
              let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            return
        }
        
        // 1. 先把当前处理后的画面拷进冻结纹理，这一帧仍显示原图
        if capture {
            guard let fromTexture = ensureFromTexture(width: frame.frameWidth, height: frame.frameHeight),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            encoder.setComputePipelineState(copyPipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(fromTexture, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            stateLock.lock()
            pendingCapture = false
            playing = true
            startTime = CACurrentMediaTime()
            stateLock.unlock()
            return
        }
        
        guard isPlaying, let fromTexture = fromTexture,
              fromTexture.width == frame.frameWidth,
              fromTexture.height == frame.frameHeight else {
            stateLock.lock()
            playing = false
            stateLock.unlock()
            return
        }
        
        // 2. 用经过时间算进度，结束则透传并关掉节点
        stateLock.lock()
        let elapsed = CACurrentMediaTime() - startTime
        stateLock.unlock()
        let duration = durationSeconds(from: slider)
        let rawProgress = Float(min(1, max(0, elapsed / duration)))
        if rawProgress >= 0.999 {
            stateLock.lock()
            playing = false
            stateLock.unlock()
            return
        }
        
        guard let destPixelBuffer = pixelBufferPool.createPixelBuffer(),
              let destPair = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer),
              let mixEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        let packed: [Float] = [Float(style.rawValue), rawProgress]
        let paramsBuffer = defalutMetal.device?.makeBuffer(
            bytes: packed,
            length: packed.count * MemoryLayout<Float>.size,
            options: []
        )
        
        mixEncoder.setComputePipelineState(mixPipeline)
        mixEncoder.setTexture(fromTexture, index: 0)
        mixEncoder.setTexture(sourceTexture, index: 1)
        mixEncoder.setTexture(destPair.1, index: 2)
        mixEncoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        mixEncoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        mixEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        mixEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = destPair.1
    }
}

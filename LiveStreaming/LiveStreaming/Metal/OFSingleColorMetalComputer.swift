//
//  OFSingleColorMetalComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  单色节点：只保留 R/G/B 或按 Rec.709 转灰度。none 时透传。
//

import Foundation
import CocoaLumberjack

/// 单通道 / 灰度处理节点。
class OFSingleColorMetalComputer: NSObject, OFProcessNode {
    /// 与 Metal kernel assistTools 的 type 参数对应
    enum SingleColorType: Int {
        /// 关闭，透传
        case none = 0
        /// 只保留红色通道
        case red
        /// 只保留绿色通道
        case green
        /// 只保留蓝色通道
        case blue
        /// Rec.709 亮度当灰度
        case gray
        
        /// 设置页展示文案
        var displayName: String {
            switch self {
            case .none:
                return "关"
            case .red:
                return "红"
            case .green:
                return "绿"
            case .blue:
                return "蓝"
            case .gray:
                return "灰"
            }
        }
    }
    
    /// 共享 Metal 设备 / 队列 / sizeBuffer
    let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 滤镜输出像素缓冲池
    let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// assistTools compute pipeline
    var pipelineState: MTLComputePipelineState?
    /// 当前通道模式；变化时同步 GPU buffer
    var colorType: SingleColorType = .none {
        didSet {
            colorTypeBuffer = defalutMetal.device?.makeBuffer(bytes: [colorType.rawValue], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
        }
    }
    /// 传给 kernel 的 type buffer
    var colorTypeBuffer: MTLBuffer?

    /// none 以外才真正跑 GPU
    var isEnabled: Bool {
        return colorType != .none
    }
    
    /// 协议入口，转给 input
    func process(_ frame: VideoFrame) {
        input(frame: frame)
    }

    /// 创建节点并编译 assistTools kernel
    override init() {
        super.init()
        setupMetal()
    }
    
    /// 从默认 library 取出 assistTools 并创建 pipeline、初始化 colorTypeBuffer
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        let program = library?.makeFunction(name: "assistTools")
        do {
            try pipelineState = defalutMetal.device?.makeComputePipelineState(function: program!)
        } catch {
            DDLogError("create single color pipeline failed: \(error)")
        }
        colorTypeBuffer = defalutMetal.device?.makeBuffer(bytes: [colorType.rawValue], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
    }
    
    /// 从 pixel buffer 创建可计算的 Metal 纹理
    /// - Parameter pixelBuffer: BGRA 像素缓冲
    /// - Returns: 包装后的 MTLTexture；失败为 nil
    func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, defalutMetal.videoTextureCache!, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
        if status != kCVReturnSuccess {
            DDLogError("create single color target texture failed")
            return nil
        }
        let outputTexture = CVMetalTextureGetTexture(texture!)
        return outputTexture
    }
    
    /// 按当前 colorType 执行 assistTools kernel
    /// - Parameter frame: 会被原地替换 pixelBuffer 与 texture
    func input(frame: VideoFrame) {
        if colorType == .none {
            return
        }
        // 1. 按帧尺寸更新线程组和输出池
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        
        // 2. 准备源纹理
        var sourceTexture: MTLTexture? = nil
        if frame.texture == nil {
            sourceTexture = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        } else {
            sourceTexture = frame.texture
        }

        // 3. 目标 buffer + 纹理
        guard let destPixelBuffer = pixelBufferPool.createPixelBuffer() else {
            return
        }
        let outputTexture = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer)
        
        // 4. 绑定纹理/通道类型并同步提交
        let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer()
        let computeEncoder = commandBuffer?.makeComputeCommandEncoder()
        
        computeEncoder?.setComputePipelineState(self.pipelineState!)
        computeEncoder?.setTexture(sourceTexture, index: 0)
        computeEncoder?.setTexture(outputTexture, index: 1)
        computeEncoder?.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        computeEncoder?.setBuffer(colorTypeBuffer, offset: 0, index: 1)

        computeEncoder?.dispatchThreadgroups(defalutMetal.numTreadGroups!, threadsPerThreadgroup: defalutMetal.threadsPerGroup!)
        computeEncoder?.endEncoding()
        
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = outputTexture
    }
}

//
//  OFPeakComputer.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  Peak 节点：高斯平滑 + Sobel 描边，用于对焦辅助。关闭时透传。
//

import Foundation
import CocoaLumberjack

/// 边缘检测处理节点。
public class OFPeakComputer: NSObject, OFProcessNode {
    /// 本实例 Metal 设备 / 队列 / sizeBuffer
    public let defalutMetal: OFDefalutMetal
    /// 本实例滤镜输出像素缓冲池
    public let pixelBufferPool: OFPixelBufferTool
    /// peak compute pipeline
    public var pipelineState: MTLComputePipelineState?
    /// 开关；写入 GPU 的 int buffer（0/1）
    public var state = false {
        didSet {
            stateBuffer = defalutMetal.device?.makeBuffer(bytes: [state ? 1 : 0], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
        }
    }
    /// 传给 kernel 的开关 buffer
    public var stateBuffer: MTLBuffer?

    /// 打开时调度器才会调用 process
    public var isEnabled: Bool {
        return state
    }
    
    /// 协议入口，转给 input
    public func process(_ frame: VideoFrame) {
        input(frame: frame)
    }

    /// 创建节点并编译 peak kernel
    /// - Parameter context: 门面注入的 GPU 资源
    public init(context: OFFilterContext) {
        self.defalutMetal = context.metal
        self.pixelBufferPool = context.pixelBufferPool
        super.init()
        setupMetal()
    }
    
    /// 从默认 library 取出 peak 并创建 pipeline、初始化 stateBuffer
    private func setupMetal() {
        let library = defalutMetal.makeShaderLibrary()
        let program = library?.makeFunction(name: "peak")
        do {
            try pipelineState = defalutMetal.device?.makeComputePipelineState(function: program!)
        } catch {
            DDLogError("create peak pipeline failed: \(error)")
        }
        stateBuffer = defalutMetal.device?.makeBuffer(bytes: [state ? 1 : 0], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
    }
    
    /// 从 pixel buffer 创建可计算的 Metal 纹理
    /// - Parameter pixelBuffer: BGRA 像素缓冲
    /// - Returns: 包装后的 MTLTexture；失败为 nil
    public func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, defalutMetal.videoTextureCache!, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
        if status != kCVReturnSuccess {
            DDLogError("create peak target texture failed")
            return nil
        }
        let outputTexture = CVMetalTextureGetTexture(texture!)
        return outputTexture
    }
    
    /// 打开时跑 peak kernel（去噪 Sobel），结果写回 frame
    /// - Parameter frame: 会被原地替换 pixelBuffer 与 texture
    public func input(frame: VideoFrame) {
        if state == false {
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
        
        // 4. 绑定纹理/开关并同步提交
        let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer()
        let computeEncoder = commandBuffer?.makeComputeCommandEncoder()
        
        computeEncoder?.setComputePipelineState(self.pipelineState!)
        computeEncoder?.setTexture(sourceTexture, index: 0)
        computeEncoder?.setTexture(outputTexture, index: 1)
        computeEncoder?.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        computeEncoder?.setBuffer(stateBuffer, offset: 0, index: 1)

        computeEncoder?.dispatchThreadgroups(defalutMetal.numTreadGroups!, threadsPerThreadgroup: defalutMetal.threadsPerGroup!)
        computeEncoder?.endEncoding()
        
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = outputTexture
    }
}

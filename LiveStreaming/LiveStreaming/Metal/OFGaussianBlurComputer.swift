//
//  OFGaussianBlurComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/7.
//
//  高斯模糊节点。CPU 生成 3×3 核，GPU 做卷积。关闭时透传。
//  G(u,v) = 1 / (2πσ²) * e^(-(u²+v²)/(2σ²))
//

import Foundation
import MetalPerformanceShaders
import CocoaLumberjack

/// 高斯模糊处理节点。
class OFGaussianBlurComputer: NSObject, OFProcessNode {
    /// 共享 Metal 设备 / 队列 / sizeBuffer
    let defalutMetal = OFDefalutMetal.standardDefalutMetal
    /// 滤镜输出像素缓冲池
    let pixelBufferPool = OFPixelBufferTool.sharedInstance
    /// gaussianBlur compute pipeline
    var pipelineState: MTLComputePipelineState?
    
    /// 自然常数 e，用于计算高斯权重
    private let EulerNumber: Float = 2.718281
    /// 卷积核系数；变化时同步 GPU buffer
    private var filter: [Float]! {
        didSet {
            gaussianBuffer = defalutMetal.device?.makeBuffer(bytes: filter, length: (radius * 2 + 1) * (radius * 2 + 1) * MemoryLayout<Float>.size, options: MTLResourceOptions(rawValue: 0))
        }
    }
    /// 核半径，1 表示 3×3
    private let radius = 1
    /// 高斯标准差；越大越糊
    var sigma: Float = 2.0 {
        didSet {
            filter = gaussianBlurFilter(sigma)
        }
    }
    /// 传给 kernel 的卷积核 buffer
    var gaussianBuffer: MTLBuffer?
    /// 开关
    var enabled = false
    
    /// 打开时调度器才会调用 process
    var isEnabled: Bool {
        return enabled
    }
    
    /// 协议入口，转给 input
    func process(_ frame: VideoFrame) {
        input(frame: frame)
    }
    
    /// 创建节点并编译 gaussianBlur kernel
    override init() {
        super.init()
        setupMetal()
    }
    
    /// 从默认 library 取出 gaussianBlur 并创建 pipeline、生成默认核
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        let program = library?.makeFunction(name: "gaussianBlur")
        do {
            try pipelineState = defalutMetal.device?.makeComputePipelineState(function: program!)
        } catch {
            DDLogError("create gaussian blur pipeline failed: \(error)")
        }
        filter = gaussianBlurFilter(sigma)
    }
    
    /// 计算核上某点的高斯权重
    /// - Parameters:
    ///   - x: 相对中心的水平偏移
    ///   - y: 相对中心的垂直偏移
    ///   - sigma: 标准差
    /// - Returns: 未归一化权重
    private func getWeight(at x: Int, y: Int, sigma: Float) -> Float {
        return 1.0 / (2.0 * Float.pi * sigma * sigma) * powf(EulerNumber, -Float(x * x + y * y) / (2.0 * sigma * sigma))
    }
    
    /// 生成归一化卷积核
    /// - Parameter sigma: 标准差
    /// - Returns: 按行展开的 (2r+1)² 个系数，和为 1
    private func gaussianBlurFilter(_ sigma: Float) -> [Float] {
        var filter: [Float] = []
        var sum: Float = 0
        for y in -radius...radius {
            for x in -radius...radius {
                let weight = getWeight(at: x, y: y, sigma: sigma)
                sum += weight
                filter.append(weight)
            }
        }
        return filter.map { $0 / sum }
    }
    
    /// 从 pixel buffer 创建可计算的 Metal 纹理
    /// - Parameter pixelBuffer: BGRA 像素缓冲
    /// - Returns: 包装后的 MTLTexture；失败为 nil
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, defalutMetal.videoTextureCache!, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
        if status != kCVReturnSuccess {
            DDLogError("create gaussian blur target texture failed")
            return nil
        }
        let outputTexture = CVMetalTextureGetTexture(texture!)
        return outputTexture
    }
    
    /// 打开时用 gaussianBlur kernel 卷积当前帧
    /// - Parameter frame: 会被原地替换 pixelBuffer 与 texture
    func input(frame: VideoFrame) {
        if enabled == false {
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
        
        // 4. 绑定纹理/卷积核并同步提交
        let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer()
        let computeEncoder = commandBuffer?.makeComputeCommandEncoder()
        
        computeEncoder?.setComputePipelineState(self.pipelineState!)
        computeEncoder?.setTexture(sourceTexture, index: 0)
        computeEncoder?.setTexture(outputTexture, index: 1)
        computeEncoder?.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        computeEncoder?.setBuffer(gaussianBuffer, offset: 0, index: 1)

        computeEncoder?.dispatchThreadgroups(defalutMetal.numTreadGroups!, threadsPerThreadgroup: defalutMetal.threadsPerGroup!)
        computeEncoder?.endEncoding()
        
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = outputTexture
    }
}

//
//  OFDefalutMetal.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  全局 Metal 上下文：设备、命令队列、纹理缓存、线程组尺寸。
//  sizeBuffer 必须用 UInt32，与 kernel 里 constant uint *size 对齐。
//

import Foundation
import CocoaLumberjack

/// 滤镜节点共用的 Metal 单例。
class OFDefalutMetal: NSObject {
    /// 全局共享实例
    static let standardDefalutMetal = OFDefalutMetal()
    /// 当前设备不支持 Metal 时为 true
    var notSupportMetal: Bool = false
    /// 系统默认 GPU
    var device: MTLDevice?
    /// 提交 compute 命令的队列
    var commandQueue: MTLCommandQueue?
    /// CVPixelBuffer ↔ MTLTexture 缓存
    var videoTextureCache: CVMetalTextureCache?
    /// 当前线程组对应的纹理宽
    var textureWidth: Int = 0
    /// 当前线程组对应的纹理高
    var textureHeight: Int = 0
    /// 每个 threadgroup 的线程数（16×16×1）
    var threadsPerGroup: MTLSize?
    /// 覆盖整幅图所需的 threadgroup 数量
    var numTreadGroups: MTLSize?
    /// kernel 读取的宽高：size[0]=width, size[1]=height，元素类型 uint32
    var sizeBuffer: MTLBuffer?
    
    /// 创建默认设备、命令队列和纹理缓存
    override init() {
        super.init()
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.notSupportMetal = true
            DDLogError("create metal device failed")
            return
        }
        self.device = device
        self.commandQueue = self.device?.makeCommandQueue()
        let error = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device!, nil, &videoTextureCache)
        if error != kCVReturnSuccess {
            DDLogError("could not create a metal texture cache, status: \(error)")
        }
    }
    
    /// 按当前帧尺寸刷新 sizeBuffer 和 dispatch 网格
    /// - Parameters:
    ///   - width: 纹理宽
    ///   - height: 纹理高
    func updateTexture(width: Int, height: Int) {
        guard textureWidth != width || textureHeight != height else {
            return
        }
        textureWidth = width
        textureHeight = height
        // 宽高用 32 位写入，避免 64 位 UInt 导致 kernel 读到 size[1]=0 全图被裁掉
        let size: [UInt32] = [UInt32(textureWidth), UInt32(textureHeight)]
        sizeBuffer = device?.makeBuffer(bytes: size, length: MemoryLayout<UInt32>.size * size.count, options: [])
        DDLogInfo("metal size buffer updated: \(textureWidth)x\(textureHeight)")
        let threadsPerGroup = MTLSizeMake(16, 16, 1)
        let numThreadGroups = MTLSizeMake(Int(ceilf(Float(textureWidth) / Float(threadsPerGroup.width))), Int(ceilf(Float(textureHeight) / Float(threadsPerGroup.height))), 1)
        self.threadsPerGroup = threadsPerGroup
        self.numTreadGroups = numThreadGroups
    }
}

//
//  OFDefalutMetal.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  每滤镜实例一份 Metal 上下文：设备、命令队列、纹理缓存、线程组尺寸。
//  sizeBuffer 必须用 UInt32，与 kernel 里 constant uint *size 对齐。
//

import Foundation
import CocoaLumberjack

/// 滤镜节点共用的 Metal 上下文（由 OFFilterContext 持有，不再用进程单例）。
public class OFDefalutMetal: NSObject {
    /// 当前设备不支持 Metal 时为 true
    public var notSupportMetal: Bool = false
    /// 系统默认 GPU
    public var device: MTLDevice?
    /// 提交 compute 命令的队列
    public var commandQueue: MTLCommandQueue?
    /// CVPixelBuffer ↔ MTLTexture 缓存
    public var videoTextureCache: CVMetalTextureCache?
    /// 当前线程组对应的纹理宽
    public var textureWidth: Int = 0
    /// 当前线程组对应的纹理高
    public var textureHeight: Int = 0
    /// 每个 threadgroup 的线程数（16×16×1）
    public var threadsPerGroup: MTLSize?
    /// 覆盖整幅图所需的 threadgroup 数量
    public var numTreadGroups: MTLSize?
    /// kernel 读取的宽高：size[0]=width, size[1]=height，元素类型 uint32
    public var sizeBuffer: MTLBuffer?
    
    /// 创建默认设备、命令队列和纹理缓存
    public override init() {
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
    public func updateTexture(width: Int, height: Int) {
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

    /// 加载滤镜 kernel。静态 Pod 的 metallib 在 `OFFilterKit.bundle`，不能假定 App main 或动态 framework。
    /// - Returns: 含滤镜 kernel 的 library
    public func makeShaderLibrary() -> MTLLibrary? {
        guard let device = device else { return nil }
        // 1. 开发源 Pod：编译期拷进 resource bundle 的 default.metallib
        if let url = OFFilterResources.bundle.url(forResource: "default", withExtension: "metallib") {
            do {
                return try device.makeLibrary(URL: url)
            } catch {
                DDLogError("load shader library from resource bundle failed: \(error)")
            }
        }
        // 2. 动态 framework / 尚未拆 Pod：模块自身的 default library
        do {
            return try device.makeDefaultLibrary(bundle: Bundle(for: OFDefalutMetal.self))
        } catch {
            DDLogError("load shader library from module failed: \(error)")
            return device.makeDefaultLibrary()
        }
    }
}

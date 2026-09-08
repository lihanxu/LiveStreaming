//
//  OFFilterContext.swift
//  LiveStreaming
//
//  一份滤镜实例的 GPU 资源：Metal 设备 + 输出像素池。由门面创建并注入各节点。
//

import Foundation

/// 滤镜运行上下文；直播与相册各持一份，互不共享像素池。
public final class OFFilterContext {
    /// 本实例的 Metal 设备 / 队列 / 纹理缓存
    public let metal: OFDefalutMetal
    /// 本实例的 CVPixelBuffer 输出池
    public let pixelBufferPool: OFPixelBufferTool

    /// 创建独立 Metal 与像素池
    public init() {
        metal = OFDefalutMetal()
        pixelBufferPool = OFPixelBufferTool()
    }
}

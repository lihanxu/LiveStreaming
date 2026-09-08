//
//  OFPixelBufferTool.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  滤镜输出用的 CVPixelBuffer 池。需同时 Metal / OpenGL ES 兼容，便于 Compute 写、预览读。
//

import Foundation
import CocoaLumberjack

/// PixelBuffer 池，避免每帧 malloc。
class OFPixelBufferTool: NSObject {
    /// 全局共享实例
    static let sharedInstance = OFPixelBufferTool()
    
    /// CoreVideo 缓冲池；尺寸或格式变化时重建
    var pixelBufferPool: CVPixelBufferPool?
    /// 当前池宽度
    var width: UInt32 = 0
    /// 当前池高度
    var height: UInt32 = 0
    /// 当前像素格式（如 32BGRA）
    var pixelFormat: OSType?
    /// 池中至少保留的 buffer 数量
    let minimumBufferCount: UInt32 = 3
    
    /// 尺寸或格式变化时刷新缓冲池
    /// - Parameters:
    ///   - width: 宽
    ///   - height: 高
    ///   - pixelFormat: pixel 类型
    func update(width: UInt32, height: UInt32, pixelFormat: OSType) {
        if pixelBufferPool != nil {
            guard self.width != width || self.height != height || self.pixelFormat != pixelFormat else {
                return
            }
            CVPixelBufferPoolFlush(pixelBufferPool!, .excessBuffers)
            pixelBufferPool = nil
        }
        createPixelBufferPool(width: width, height: height, pixelFormat: pixelFormat)
    }
    
    /// 按宽高和格式创建新池，并打开 Metal / GLES 兼容
    /// - Parameters:
    ///   - width: 宽
    ///   - height: 高
    ///   - pixelFormat: pixel 类型
    func createPixelBufferPool(width: UInt32, height: UInt32, pixelFormat: OSType) {
        DDLogInfo("create pixel buffer pool \(width)x\(height) format:\(pixelFormat)")
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        let sourcePixelBufferOptions: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelFormatOpenGLESCompatibility: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let pixelBufferPoolOptions = [kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions as CFDictionary, sourcePixelBufferOptions as CFDictionary, &pixelBufferPool)
    }

    /// 从池中取出一块可写 pixel buffer
    /// - Returns: 新的 CVPixelBuffer；池未创建时为 nil
    func createPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }
}

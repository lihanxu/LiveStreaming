//
//  OFPixelBufferTool.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFPixelBufferTool: NSObject {
    static let sharedInstance = OFPixelBufferTool()
    
    var pixelBufferPool: CVPixelBufferPool?
    var width: UInt32 = 0
    var height: UInt32 = 0
    var pixelFormat: OSType?
    let minimumBufferCount: UInt32 = 3
    
    /// 更新缓冲池
    /// - parameter width: 宽
    /// - parameter height: 高
    /// - parameter pixelFormat: pixel类型
    ///
    /// 根据pixel的类型，更新缓冲池
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
    
    /// 通过宽高等信息创建一个缓冲池
    func createPixelBufferPool(width: UInt32, height: UInt32, pixelFormat: OSType) {
        print("creat pixel buffer pool")
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        let sourcePixelBufferOptions: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelFormatOpenGLESCompatibility: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let pixelBufferPoolOptions = [kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions as CFDictionary, sourcePixelBufferOptions as CFDictionary, &pixelBufferPool)
    }

    /// 从缓冲池中创建一个buffer
    /// - Parameter pixelBuffer: 需要创建的缓存
    func createPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }
}

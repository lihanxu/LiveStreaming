//
//  OFDefalutMetal.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFDefalutMetal: NSObject {
    static let standardDefalutMetal = OFDefalutMetal()
    var notSupportMetal: Bool = false
    var device: MTLDevice?
    var commandQueue: MTLCommandQueue?
    var videoTextureCache: CVMetalTextureCache?
    var textureWidth: Int = 0
    var textureHeight: Int = 0
    var threadsPerGroup: MTLSize?
    var numTreadGroups: MTLSize?
    var sizeBuffer: MTLBuffer?
    
    override init() {
        super.init()
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.notSupportMetal = true
            print("cerror: reat metal device failed!")
            return
        }
        self.device = device
        self.commandQueue = self.device?.makeCommandQueue()
        let error = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device!, nil, &videoTextureCache)
        if error != kCVReturnSuccess {
            print("error: could not create a texture cache")
        }
    }
    
    /// 更新纹理的Size
    /// - parameter width: 宽
    /// - parameter height: 高
    ///
    /// 更新纹理的宽和高，这会刷新线程组的信息
    func updateTexture(width: Int, height: Int) {
        guard textureWidth != width || textureHeight != height else {
            return
        }
        textureWidth = width
        textureHeight = height
        let size = [UInt(textureWidth), UInt(textureHeight)]
        sizeBuffer = device?.makeBuffer(bytes: size, length: 2 * MemoryLayout<UInt>.size, options: .cpuCacheModeWriteCombined)
        let threadsPerGroup = MTLSizeMake(16, 16, 1)
        let numThreadGroups = MTLSizeMake(Int(ceilf(Float(textureWidth) / Float(threadsPerGroup.width))), Int(ceilf(Float(textureHeight) / Float(threadsPerGroup.height))), 1)
        self.threadsPerGroup = threadsPerGroup
        self.numTreadGroups = numThreadGroups
    }
}

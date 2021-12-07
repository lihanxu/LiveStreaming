//
//  OFPeakComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFPeakComputer: NSObject {
    let defalutMetal = OFDefalutMetal.standardDefalutMetal
    let pixelBufferPool = OFPixelBufferTool.sharedInstance
    var pipelineState: MTLComputePipelineState?
    var state = false {
        didSet {
            stateBuffer = defalutMetal.device?.makeBuffer(bytes: [state ? 1 : 0], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
        }
    }
    var stateBuffer: MTLBuffer?

    override init() {
        super.init()
        setupMetal()
    }
    
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        let program = library?.makeFunction(name: "peak")
        do {
            try pipelineState = defalutMetal.device?.makeComputePipelineState(function: program!)
        } catch {
            print(("(Assistive tools) error: create compute pipeline failed!"))
        }
        stateBuffer = defalutMetal.device?.makeBuffer(bytes: [state ? 1 : 0], length: MemoryLayout<Int>.size, options: MTLResourceOptions(rawValue: 0))
    }
    
    func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, defalutMetal.videoTextureCache!, pixelBuffer, nil, pixelFormat, width, height, 0, &texture)
        if status != kCVReturnSuccess {
            print("error: creat Target Texture failed")
            return nil
        }
        let outputTexture = CVMetalTextureGetTexture(texture!)
        return outputTexture
    }
    
    func input(frame: VideoFrame) {
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        
        var sourceTexture: MTLTexture? = nil
        if frame.texture == nil {
            sourceTexture = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        } else {
            sourceTexture = frame.texture
        }

        guard let destPixelBuffer = pixelBufferPool.createPixelBuffer() else {
            return
        }
        let outputTexture = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer)
        
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

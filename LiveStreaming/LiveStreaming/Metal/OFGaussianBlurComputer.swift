//
//  OFGaussianBlurComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/7.
//

import Foundation
import MetalPerformanceShaders

//G(u,v) = 1 / (2 * pi * sigma * sigma) * e^{-(u^2 + v^2)/(2 \sigma^2)}

class OFGaussianBlurComputer: NSObject {
    let defalutMetal = OFDefalutMetal.standardDefalutMetal
    let pixelBufferPool = OFPixelBufferTool.sharedInstance
    var pipelineState: MTLComputePipelineState?
    
    private let EulerNumber: Float = 2.718281
    private var filter: [Float]! {
        didSet {
            gaussianBuffer = defalutMetal.device?.makeBuffer(bytes: filter, length: (radius * 2 + 1) * (radius * 2 + 1) * MemoryLayout<Float>.size, options: MTLResourceOptions(rawValue: 0))
        }
    }
    private let radius = 1
    var sigma: Float = 2.0 {
        didSet {
            filter = gaussianBlurFilter(sigma)
        }
    }
    var gaussianBuffer: MTLBuffer?
    var enabled = false
    
    override init() {
        super.init()
        setupMetal()
    }
    
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        let program = library?.makeFunction(name: "gaussianBlur")
        do {
            try pipelineState = defalutMetal.device?.makeComputePipelineState(function: program!)
        } catch {
            print(("(Assistive tools) error: create compute pipeline failed!"))
        }
        filter = gaussianBlurFilter(sigma)
    }
    
    private func getWeight(at x: Int, y: Int, sigma: Float) -> Float {
        return 1.0 / (2.0 * Float.pi * sigma * sigma) * powf(EulerNumber, -Float(x * x + y * y) / (2.0 * sigma * sigma))
    }
    
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
    
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
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
        if enabled == false {
            return
        }
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
        computeEncoder?.setBuffer(gaussianBuffer, offset: 0, index: 1)

        computeEncoder?.dispatchThreadgroups(defalutMetal.numTreadGroups!, threadsPerThreadgroup: defalutMetal.threadsPerGroup!)
        computeEncoder?.endEncoding()
        
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = outputTexture
    }
}

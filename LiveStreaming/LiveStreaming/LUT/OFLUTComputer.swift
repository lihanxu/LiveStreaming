//
//  OFLUTComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation
import Metal

struct OFLUTPreset {
    let displayName: String
    let fileName: String?
    
    static let all: [OFLUTPreset] = [
        OFLUTPreset(displayName: "LUT", fileName: nil),
        OFLUTPreset(displayName: "Rec709", fileName: "Rec709 normal"),
        OFLUTPreset(displayName: "sRGB", fileName: "SRGB normal"),
        OFLUTPreset(displayName: "ACES", fileName: "ACESAP0 normal"),
    ]
}

class OFLUTComputer: NSObject, OFProcessNode {
    private let defalutMetal = OFDefalutMetal.standardDefalutMetal
    private let pixelBufferPool = OFPixelBufferTool.sharedInstance
    private var pipelineState: MTLComputePipelineState?
    private var lutTexture: MTLTexture?
    private var presetIndex = 0
    
    var currentPreset: OFLUTPreset {
        return OFLUTPreset.all[presetIndex]
    }
    
    var isEnabled: Bool {
        return currentPreset.fileName != nil && lutTexture != nil && pipelineState != nil
    }
    
    override init() {
        super.init()
        setupMetal()
    }
    
    private func setupMetal() {
        let library = defalutMetal.device?.makeDefaultLibrary()
        guard let program = library?.makeFunction(name: "ColorLUT") else {
            print("ColorLUT kernel not found")
            return
        }
        do {
            pipelineState = try defalutMetal.device?.makeComputePipelineState(function: program)
        } catch {
            print("create ColorLUT pipeline failed: \(error)")
        }
    }
    
    @discardableResult
    func switchToNext() -> OFLUTPreset {
        presetIndex = (presetIndex + 1) % OFLUTPreset.all.count
        loadCurrentLUT()
        return currentPreset
    }
    
    private func loadCurrentLUT() {
        lutTexture = nil
        guard let fileName = currentPreset.fileName, let device = defalutMetal.device else {
            return
        }
        lutTexture = OFLUTLoader.loadTexture(named: fileName, device: device)
    }
    
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = MTLPixelFormat.bgra8Unorm
        
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            defalutMetal.videoTextureCache!,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &texture
        )
        if status != kCVReturnSuccess {
            print("error: creat LUT texture failed")
            return nil
        }
        return CVMetalTextureGetTexture(texture!)
    }
    
    func process(_ frame: VideoFrame) {
        guard isEnabled, let pipelineState = pipelineState, let lutTexture = lutTexture else {
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
        
        computeEncoder?.setComputePipelineState(pipelineState)
        computeEncoder?.setTexture(sourceTexture, index: 0)
        computeEncoder?.setTexture(lutTexture, index: 1)
        computeEncoder?.setTexture(outputTexture, index: 2)
        computeEncoder?.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        
        computeEncoder?.dispatchThreadgroups(defalutMetal.numTreadGroups!, threadsPerThreadgroup: defalutMetal.threadsPerGroup!)
        computeEncoder?.endEncoding()
        
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = outputTexture
    }
}

//
//  OFLUTComputer.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation
import Metal
import CocoaLumberjack

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
    private var didLogProcessInfo = false
    
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
            DDLogError("ColorLUT kernel not found")
            return
        }
        do {
            pipelineState = try defalutMetal.device?.makeComputePipelineState(function: program)
            DDLogInfo("ColorLUT pipeline ready")
        } catch {
            DDLogError("create ColorLUT pipeline failed: \(error)")
        }
    }
    
    @discardableResult
    func switchToNext() -> OFLUTPreset {
        presetIndex = (presetIndex + 1) % OFLUTPreset.all.count
        loadCurrentLUT()
        didLogProcessInfo = false
        DDLogInfo("switch LUT to \(currentPreset.displayName), enabled:\(isEnabled)")
        return currentPreset
    }
    
    private func loadCurrentLUT() {
        lutTexture = nil
        guard let fileName = currentPreset.fileName, let device = defalutMetal.device else {
            DDLogInfo("LUT disabled")
            return
        }
        lutTexture = OFLUTLoader.loadTexture(named: fileName, device: device)
        if let lutTexture = lutTexture {
            DDLogInfo("LUT texture loaded: \(fileName) \(lutTexture.width)x\(lutTexture.height) format:\(lutTexture.pixelFormat.rawValue)")
        } else {
            DDLogError("LUT texture load failed: \(fileName)")
        }
    }
    
    private func createTextureFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let textureCache = defalutMetal.videoTextureCache else {
            DDLogError("metal texture cache is nil")
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            DDLogError("create LUT metal texture failed, status: \(status) size:\(width)x\(height)")
            return nil
        }
        return (cvTexture, texture)
    }
    
    func process(_ frame: VideoFrame) {
        guard isEnabled, let pipelineState = pipelineState, let lutTexture = lutTexture else {
            return
        }
        defalutMetal.updateTexture(width: frame.frameWidth, height: frame.frameHeight)
        pixelBufferPool.update(width: UInt32(frame.frameWidth), height: UInt32(frame.frameHeight), pixelFormat: kCVPixelFormatType_32BGRA)
        
        let sourcePair: (CVMetalTexture, MTLTexture)?
        if let existing = frame.texture {
            sourcePair = nil
            if !didLogProcessInfo {
                DDLogInfo("LUT source uses existing metal texture \(existing.width)x\(existing.height)")
            }
        } else {
            sourcePair = createTextureFromPixelBuffer(pixelBuffer: frame.pixelBuffer)
        }
        let sourceTexture = sourcePair?.1 ?? frame.texture
        guard let sourceTexture = sourceTexture else {
            DDLogError("LUT source texture is nil, skip")
            return
        }
        
        guard let destPixelBuffer = pixelBufferPool.createPixelBuffer() else {
            DDLogError("LUT dest pixel buffer create failed")
            return
        }
        guard let destPair = createTextureFromPixelBuffer(pixelBuffer: destPixelBuffer) else {
            return
        }
        
        guard let commandBuffer = defalutMetal.commandQueue?.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let threadgroups = defalutMetal.numTreadGroups,
              let threadsPerGroup = defalutMetal.threadsPerGroup else {
            DDLogError("LUT metal command encoder create failed")
            return
        }
        
        if !didLogProcessInfo {
            DDLogInfo("LUT process frame:\(frame.frameWidth)x\(frame.frameHeight) lut:\(lutTexture.width)x\(lutTexture.height) groups:\(threadgroups.width)x\(threadgroups.height)")
            didLogProcessInfo = true
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(sourceTexture, index: 0)
        computeEncoder.setTexture(lutTexture, index: 1)
        computeEncoder.setTexture(destPair.1, index: 2)
        computeEncoder.setBuffer(defalutMetal.sizeBuffer, offset: 0, index: 0)
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if commandBuffer.status != .completed {
            DDLogError("LUT compute status:\(commandBuffer.status.rawValue) error:\(String(describing: commandBuffer.error))")
            return
        }
        
        frame.pixelBuffer = destPixelBuffer
        frame.texture = destPair.1
        _ = sourcePair
        _ = destPair
    }
}

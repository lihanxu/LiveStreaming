//
//  OFLUTLoader.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import UIKit
import Metal
import CocoaLumberjack

class OFLUTLoader {
    static func loadTexture(named name: String, device: MTLDevice) -> MTLTexture? {
        guard let image = UIImage(named: name), let cgImage = image.cgImage else {
            DDLogError("load LUT image failed: \(name)")
            return nil
        }
        
        let width = cgImage.width
        let height = cgImage.height
        DDLogInfo("load LUT image \(name) \(width)x\(height)")
        if width != 512 || height != 512 {
            DDLogError("LUT image size is \(width)x\(height), ColorLUT kernel expects 512x512")
        }
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            DDLogError("LUT color space create failed")
            return nil
        }
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            DDLogError("LUT bitmap context create failed")
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            DDLogError("LUT metal texture create failed")
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: rawData,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}

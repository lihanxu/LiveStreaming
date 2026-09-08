//
//  OFLUTLoader.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  把 Bundle 里的 PNG 色表（64³ LUT 排成 8×8 的 64×64 切片，共 512×512）上传为 Metal 纹理。
//

import UIKit
import Metal
import CocoaLumberjack

/// 从图片资源创建 LUT 采样纹理。
public class OFLUTLoader {
    /// 读取 PNG，转成 sRGB RGBA8，再上传为 shaderRead 纹理
    /// - Parameters:
    ///   - name: UIImage 资源名，对应「Rec709 normal」这类 PNG
    ///   - device: 用于创建 MTLTexture 的设备
    /// - Returns: 可被 ColorLUT kernel 采样的 2D 纹理；失败为 nil
    public static func loadTexture(named name: String, device: MTLDevice) -> MTLTexture? {
        guard let image = UIImage(named: name, in: OFFilterResources.bundle, compatibleWith: nil),
              let cgImage = image.cgImage else {
            DDLogError("load LUT image failed: \(name)")
            return nil
        }
        
        let width = cgImage.width
        let height = cgImage.height
        DDLogInfo("load LUT image \(name) \(width)x\(height)")
        if width != 512 || height != 512 {
            DDLogError("LUT image size is \(width)x\(height), ColorLUT kernel expects 512x512")
        }
        
        // 1. 把 CGImage 画进连续 RGBA 内存，避免 PNG 行对齐/颜色空间不一致
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
        
        // 2. 创建只读纹理并把像素拷上去
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

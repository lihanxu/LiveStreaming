//
//  AlbumMediaConverter.swift
//  LiveStreaming
//
//  相册像素与处理图之间的格式转换：方向烘焙、尺寸限制、Buffer 拷贝。
//

import UIKit
import AVFoundation
import Photos
import CoreVideo
import OFFilterKit

/// 相册媒体 ↔ VideoFrame / PixelBuffer 工具；与采集链路统一 32BGRA。
enum AlbumMediaConverter {
    /// 预览长边上限：对齐屏幕像素，避免 3x 屏上被放大发糊
    static var previewMaxLongEdge: CGFloat {
        let native = UIScreen.main.nativeBounds.size
        return max(native.width, native.height)
    }
    /// 照片导出长边上限
    static let photoExportMaxLongEdge: CGFloat = 4096
    /// 视频导出长边上限
    static let videoExportMaxLongEdge: CGFloat = 1920

    /// 按长边等比缩放后的宽高
    /// - Parameters:
    ///   - originalWidth: 原始宽
    ///   - originalHeight: 原始高
    ///   - maxLongEdge: 长边上限
    /// - Returns: 缩放后整数宽高
    static func scaledSize(originalWidth: Int, originalHeight: Int, maxLongEdge: CGFloat) -> (Int, Int) {
        let width = CGFloat(originalWidth)
        let height = CGFloat(originalHeight)
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else {
            return (max(1, originalWidth), max(1, originalHeight))
        }
        let scale = maxLongEdge / longEdge
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    /// H.264 要求宽高为偶数，否则 VideoToolbox 会直接 abort
    /// - Parameters:
    ///   - width: 宽
    ///   - height: 高
    /// - Returns: 向下收成偶数且至少为 2
    static func evenSize(width: Int, height: Int) -> (Int, Int) {
        return (max(2, width / 2 * 2), max(2, height / 2 * 2))
    }

    /// 由 PixelBuffer 构造 VideoFrame
    /// - Parameter pixelBuffer: 32BGRA 缓冲
    /// - Returns: 与直播采集相同结构的帧
    static func makeVideoFrame(from pixelBuffer: CVPixelBuffer) -> VideoFrame {
        let frame = VideoFrame()
        frame.frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        frame.frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        frame.pixelBuffer = pixelBuffer
        return frame
    }

    /// 深拷贝 PixelBuffer（处理图会原地改 buffer，照片需从 source 重跑）
    /// - Parameter source: 原始 BGRA
    /// - Returns: 独立副本；失败为 nil
    static func copyPixelBuffer(_ source: CVPixelBuffer, pool: OFPixelBufferTool) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        pool.update(width: UInt32(width), height: UInt32(height), pixelFormat: format)
        guard let destination = pool.createPixelBuffer() else {
            return nil
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(destination) else {
            return nil
        }
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(destination)
        let copyBytes = min(srcRow, dstRow)
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstRow), srcBase.advanced(by: row * srcRow), copyBytes)
        }
        return destination
    }

    /// UIImage 转 BGRA；draw 时烘焙 orientation
    /// - Parameters:
    ///   - image: 系统相册返回的图
    ///   - maxLongEdge: 长边上限
    /// - Returns: 可进处理图的 buffer
    static func pixelBuffer(from image: UIImage, maxLongEdge: CGFloat, pool: OFPixelBufferTool) -> CVPixelBuffer? {
        guard let cgImage = normalizedCGImage(from: image, maxLongEdge: maxLongEdge) else {
            return nil
        }
        return pixelBuffer(from: cgImage, pool: pool)
    }

    /// 烘焙方向并按长边缩放；必须用像素宽高，不能用 size（点）否则 Retina 图会被压糊
    /// - Parameters:
    ///   - image: 源图
    ///   - maxLongEdge: 长边上限（像素）
    /// - Returns: 正向 CGImage
    static func normalizedCGImage(from image: UIImage, maxLongEdge: CGFloat) -> CGImage? {
        let pixelWidth: Int
        let pixelHeight: Int
        if let cgImage = image.cgImage {
            pixelWidth = cgImage.width
            pixelHeight = cgImage.height
        } else {
            pixelWidth = max(1, Int(image.size.width * image.scale))
            pixelHeight = max(1, Int(image.size.height * image.scale))
        }
        let (targetWidth, targetHeight) = scaledSize(
            originalWidth: pixelWidth,
            originalHeight: pixelHeight,
            maxLongEdge: maxLongEdge
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetHeight), format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
        return drawn.cgImage
    }

    /// CGImage 写入新 BGRA buffer
    /// - Parameter cgImage: 已烘焙方向的图
    /// - Returns: Metal/GLES 兼容 buffer
    static func pixelBuffer(from cgImage: CGImage, pool: OFPixelBufferTool) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        pool.update(
            width: UInt32(width),
            height: UInt32(height),
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        guard let buffer = pool.createPixelBuffer() else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// BGRA buffer 转 UIImage（导出照片用）
    /// - Parameter pixelBuffer: 处理后的 buffer
    /// - Returns: 可写入相册的图
    static func uiImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 将 buffer 缩放到目标尺寸；只用 CoreGraphics，可在后台队列调用
    /// - Parameters:
    ///   - source: 源 BGRA
    ///   - targetWidth: 目标宽
    ///   - targetHeight: 目标高
    /// - Returns: 缩放后的新 buffer
    static func scaledPixelBuffer(_ source: CVPixelBuffer, targetWidth: Int, targetHeight: Int, pool: OFPixelBufferTool) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(source)
        let srcHeight = CVPixelBufferGetHeight(source)
        if srcWidth == targetWidth && srcHeight == targetHeight {
            return copyPixelBuffer(source, pool: pool)
        }
        guard let cgImage = cgImage(from: source) else {
            return nil
        }
        pool.update(
            width: UInt32(targetWidth),
            height: UInt32(targetHeight),
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        guard let buffer = pool.createPixelBuffer() else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return buffer
    }

    /// PixelBuffer 转 CGImage，不走 UIKit
    /// - Parameter pixelBuffer: BGRA
    /// - Returns: CGImage
    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }

    /// 异步加载照片为 BGRA source buffer
    /// - Parameters:
    ///   - asset: 相册资源
    ///   - maxLongEdge: 长边上限
    ///   - completion: 主线程回调
    static func loadPhotoBuffer(
        asset: PHAsset,
        maxLongEdge: CGFloat,
        pool: OFPixelBufferTool,
        completion: @escaping (CVPixelBuffer?) -> Void
    ) {
        let (targetWidth, targetHeight) = scaledSize(
            originalWidth: asset.pixelWidth,
            originalHeight: asset.pixelHeight,
            maxLongEdge: maxLongEdge
        )
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            // 第一次回调常是缩略图，丢掉会一直糊
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                return
            }
            DispatchQueue.main.async {
                guard let image = image else {
                    completion(nil)
                    return
                }
                completion(pixelBuffer(from: image, maxLongEdge: maxLongEdge, pool: pool))
            }
        }
    }

    /// 异步加载视频 AVAsset
    /// - Parameters:
    ///   - asset: 相册视频
    ///   - completion: 主线程回调
    static func loadVideoAsset(asset: PHAsset, completion: @escaping (AVAsset?) -> Void) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            DispatchQueue.main.async {
                completion(avAsset)
            }
        }
    }
}

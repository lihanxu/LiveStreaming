//
//  AlbumTransitionKernel.swift
//  LiveStreaming
//
//  工程画布上的接缝混叠：几何 + cover 之后、滤镜之前。无实例。
//

import CoreImage
import CoreVideo
import OFFilterKit

/// 两路已贴合同一画布的 32BGRA 按转场类型混成一路。
enum AlbumTransitionKernel {
    /// 与几何内核共用工作色域，避免每帧新建 context
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// 交叉淡化或闪黑/闪白。
    /// - Parameters:
    ///   - outgoing: 当前段画布帧
    ///   - incoming: 下一段画布帧；缺则退回 outgoing
    ///   - progress: 0 全是 outgoing，1 全是 incoming
    ///   - kind: `cut` 不混
    ///   - pool: 输出池
    /// - Returns: 新 buffer；失败则 outgoing
    static func mix(
        outgoing: CVPixelBuffer,
        incoming: CVPixelBuffer?,
        progress: Float,
        kind: AlbumTransitionKind,
        pool: OFPixelBufferTool
    ) -> CVPixelBuffer {
        let t = min(max(progress, 0), 1)
        if kind == .cut || t <= 0.0001 || incoming == nil {
            return outgoing
        }
        guard let incoming = incoming, t < 0.999 else {
            return incoming ?? outgoing
        }
        let fromImage = CIImage(cvPixelBuffer: outgoing)
        let toImage = CIImage(cvPixelBuffer: incoming)
        let extent = fromImage.extent.integral
        guard extent.width >= 1, extent.height >= 1 else {
            return outgoing
        }
        let alignedTo = toImage.cropped(to: extent)
        let mixed: CIImage
        switch kind {
        case .cut:
            return outgoing
        case .fade:
            mixed = dissolve(from: fromImage, to: alignedTo, time: t)
        case .dipToBlack:
            mixed = dip(from: fromImage, to: alignedTo, time: t, white: false, extent: extent)
        case .dipToWhite:
            mixed = dip(from: fromImage, to: alignedTo, time: t, white: true, extent: extent)
        }
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        pool.update(width: UInt32(width), height: UInt32(height), pixelFormat: kCVPixelFormatType_32BGRA)
        guard let destination = pool.createPixelBuffer() else {
            return outgoing
        }
        ciContext.render(
            mixed,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }

    /// CI 交叉溶解
    /// - Parameters:
    ///   - from: 出段
    ///   - to: 入段
    ///   - time: 0…1
    /// - Returns: 混叠图
    private static func dissolve(from: CIImage, to: CIImage, time: Float) -> CIImage {
        return from.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                kCIInputTargetImageKey: to,
                kCIInputTimeKey: NSNumber(value: time),
            ]
        )
    }

    /// 先淡到纯色再从纯色淡入；中点 t=0.5
    /// - Parameters:
    ///   - from: 出段
    ///   - to: 入段
    ///   - time: 0…1
    ///   - white: 闪白，否则闪黑
    ///   - extent: 画布
    /// - Returns: 混叠图
    private static func dip(
        from: CIImage,
        to: CIImage,
        time: Float,
        white: Bool,
        extent: CGRect
    ) -> CIImage {
        let color = CIColor(red: white ? 1 : 0, green: white ? 1 : 0, blue: white ? 1 : 0, alpha: 1)
        let solid = CIImage(color: color).cropped(to: extent)
        if time < 0.5 {
            return dissolve(from: from, to: solid, time: time * 2)
        }
        return dissolve(from: solid, to: to, time: (time - 0.5) * 2)
    }
}

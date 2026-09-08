//
//  AlbumGeometryKernel.swift
//  LiveStreaming
//
//  单帧画幅：片源朝向 + 用户旋转/翻转/自由角/比例，一次 CI render。禁止黑边进滤镜。
//

import CoreImage
import CoreVideo
import CoreGraphics
import OFFilterKit

/// 对照片/视频帧做几何；后台队列调用，不用 UIKit 绘图。
enum AlbumGeometryKernel {
    /// 复用 CIContext，避免每帧新建
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// 把源帧变成正放、铺满、已裁切的 BGRA。
    /// - Parameters:
    ///   - source: 输入 32BGRA；照片已 bake 朝向，视频传编码朝向
    ///   - geometry: 用户画幅
    ///   - preferredTransform: 视频轨朝向；照片传 identity
    ///   - pool: 输出池
    /// - Returns: 新 buffer；失败 nil
    static func apply(
        source: CVPixelBuffer,
        geometry: AlbumGeometryEdit,
        preferredTransform: CGAffineTransform = .identity,
        pool: OFPixelBufferTool
    ) -> CVPixelBuffer? {
        let orientation = AlbumMediaConverter.cgImageOrientation(from: preferredTransform)
        let needsTrackOrient: Bool
        if let orientation = orientation {
            needsTrackOrient = orientation != .up
        } else {
            needsTrackOrient = !preferredTransform.isIdentity
        }
        if geometry.isIdentity && !needsTrackOrient {
            return AlbumMediaConverter.copyPixelBuffer(source, pool: pool)
        }

        var image = CIImage(cvPixelBuffer: source)
        // 1. 片源朝向：与 AlbumMediaConverter.orientedPixelBuffer 同一套映射
        if let orientation = orientation, orientation != .up {
            image = image.oriented(orientation)
        } else if needsTrackOrient {
            image = image.transformed(by: preferredTransform)
        }
        image = normalizedOrigin(image)
        guard image.extent.width >= 1, image.extent.height >= 1, !image.extent.isInfinite else {
            return nil
        }

        // 2. 正交旋转（顺时针 90° × n）
        let turns = geometry.normalizedQuarterTurns
        if turns > 0 {
            let radians = -CGFloat(turns) * .pi / 2
            image = rotatedAroundCenter(image, radians: radians)
            image = normalizedOrigin(image)
        }

        // 3. 左右 / 上下翻转
        if geometry.flipHorizontal {
            image = flipped(image, horizontal: true)
        }
        if geometry.flipVertical {
            image = flipped(image, vertical: true)
        }

        // 4. 自由角：先旋转再 cover 放大，裁回旋转前尺寸，避免黑角进滤镜
        let angle = CGFloat(geometry.freeAngleDegrees)
        if abs(angle) >= 0.01 {
            image = applyFreeAngleCover(image, degrees: angle)
        }

        // 5. 比例：居中裁成目标宽高比
        if let aspect = geometry.aspect.aspectRatio {
            image = centerCrop(image, aspectRatio: aspect)
        }

        image = normalizedOrigin(image)
        let extent = image.extent.integral
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        pool.update(width: UInt32(width), height: UInt32(height), pixelFormat: kCVPixelFormatType_32BGRA)
        guard let destination = pool.createPixelBuffer() else {
            return nil
        }
        ciContext.render(
            image,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }

    /// 几何后像素宽高，供导出 Writer 先定画布；与 `apply` 的裁切顺序一致。
    /// - Parameters:
    ///   - sourceWidth: 编码宽
    ///   - sourceHeight: 编码高
    ///   - geometry: 用户画幅
    ///   - preferredTransform: 视频轨朝向；照片传 identity
    /// - Returns: 未做 1920/偶数对齐的几何输出尺寸
    static func outputPixelSize(
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: AlbumGeometryEdit,
        preferredTransform: CGAffineTransform = .identity
    ) -> (Int, Int) {
        var width = CGFloat(max(1, sourceWidth))
        var height = CGFloat(max(1, sourceHeight))
        // 1. 片源朝向：EXIF 90/270 互换宽高；对不齐的仿射取包围盒
        if let orientation = AlbumMediaConverter.cgImageOrientation(from: preferredTransform) {
            switch orientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                swap(&width, &height)
            default:
                break
            }
        } else if !preferredTransform.isIdentity {
            let corners = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: width, y: 0),
                CGPoint(x: 0, y: height),
                CGPoint(x: width, y: height),
            ].map { $0.applying(preferredTransform) }
            let minX = corners.map { $0.x }.min() ?? 0
            let maxX = corners.map { $0.x }.max() ?? width
            let minY = corners.map { $0.y }.min() ?? 0
            let maxY = corners.map { $0.y }.max() ?? height
            width = max(1, abs(maxX - minX))
            height = max(1, abs(maxY - minY))
        }
        // 2. 正交 90°：奇数次互换宽高；翻转/自由角 cover 后仍是该矩形
        if geometry.normalizedQuarterTurns % 2 == 1 {
            swap(&width, &height)
        }
        // 3. 比例居中裁切，extent.integral 与 apply 对齐
        if let aspect = geometry.aspect.aspectRatio, aspect > 0 {
            let sourceAspect = width / max(height, 0.001)
            var crop = CGRect(x: 0, y: 0, width: width, height: height)
            if sourceAspect > aspect {
                let newWidth = height * aspect
                crop.origin.x = (width - newWidth) / 2
                crop.size.width = newWidth
            } else if sourceAspect < aspect {
                let newHeight = width / aspect
                crop.origin.y = (height - newHeight) / 2
                crop.size.height = newHeight
            }
            crop = crop.integral
            width = max(1, crop.width)
            height = max(1, crop.height)
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height).integral
        return (max(1, Int(extent.width)), max(1, Int(extent.height)))
    }

    /// 把 extent 原点拉回 (0,0)，否则 render 会画出空白
    /// - Parameter image: 任意 extent 的 CIImage
    /// - Returns: 原点归零后的图
    private static func normalizedOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        if origin == .zero {
            return image
        }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// 绕画面中心旋转
    /// - Parameters:
    ///   - image: 输入
    ///   - radians: CI 坐标系（y 向上）；负值在预览上为顺时针
    /// - Returns: 旋转后的图
    private static func rotatedAroundCenter(_ image: CIImage, radians: CGFloat) -> CIImage {
        let extent = image.extent
        let cx = extent.midX
        let cy = extent.midY
        let transform = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: radians)
            .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: transform)
    }

    /// 水平或垂直镜像；调用方保证 origin 已归零
    /// - Parameters:
    ///   - image: 输入
    ///   - horizontal: 左右翻转
    ///   - vertical: 上下翻转
    /// - Returns: 翻转后的图
    private static func flipped(_ image: CIImage, horizontal: Bool = false, vertical: Bool = false) -> CIImage {
        let extent = image.extent
        var transform = CGAffineTransform.identity
        if horizontal {
            transform = transform.scaledBy(x: -1, y: 1).translatedBy(x: -extent.width, y: 0)
        }
        if vertical {
            transform = transform.scaledBy(x: 1, y: -1).translatedBy(x: 0, y: -extent.height)
        }
        return image.transformed(by: transform)
    }

    /// 自由角后放大铺满原矩形，再裁回，保证无黑边
    /// - Parameters:
    ///   - image: 正交+翻转之后的图
    ///   - degrees: 自由角（度），正值逆时针
    /// - Returns: 与输入同尺寸、已铺满的图
    private static func applyFreeAngleCover(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let extent = image.extent
        let width = extent.width
        let height = extent.height
        let radians = degrees * .pi / 180
        var result = rotatedAroundCenter(image, radians: radians)
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        // 旋转后要盖住原 W×H，所需最小放大倍数
        let scale = max(
            (width * cosine + height * sine) / width,
            (width * sine + height * cosine) / height
        )
        if scale > 1.001 {
            let cx = result.extent.midX
            let cy = result.extent.midY
            let scaleTransform = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -cx, y: -cy)
            result = result.transformed(by: scaleTransform)
        }
        let center = CGPoint(x: result.extent.midX, y: result.extent.midY)
        let crop = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        return result.cropped(to: crop)
    }

    /// 居中裁成目标宽高比
    /// - Parameters:
    ///   - image: 输入
    ///   - aspectRatio: 宽/高
    /// - Returns: 裁切后的图
    private static func centerCrop(_ image: CIImage, aspectRatio: CGFloat) -> CIImage {
        guard aspectRatio > 0 else { return image }
        let extent = image.extent
        let sourceAspect = extent.width / max(extent.height, 0.001)
        var crop = extent
        if sourceAspect > aspectRatio {
            let newWidth = extent.height * aspectRatio
            crop.origin.x = extent.minX + (extent.width - newWidth) / 2
            crop.size.width = newWidth
        } else if sourceAspect < aspectRatio {
            let newHeight = extent.width / aspectRatio
            crop.origin.y = extent.minY + (extent.height - newHeight) / 2
            crop.size.height = newHeight
        }
        return image.cropped(to: crop.integral)
    }
}

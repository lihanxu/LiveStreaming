//
//  OFFaceRegionMask.swift
//  LiveStreaming
//
//  根据 MediaPipe 478 点网格，在小纹理上栅格化皮肤 / 眼睛 / 牙齿遮罩。
//  R=皮肤（磨皮、美白），G=眼睛（亮眼），B=牙齿（白牙）。
//  对齐 self-beauty-core 无分割模型时的降级：FACE_OVAL 作面部皮肤，
//  眉毛/嘴唇从皮肤抠掉；眼裂用 MediaPipe 眼轮廓写 G、不挖皮肤；张嘴才填牙齿。
//  眼睑软边靠 GPU 线性采样，不在 CPU 上羽化，以免拖垮采集线程。
//

import Foundation
import CoreGraphics
import Metal
import CocoaLumberjack

/// 把人脸关键点画成 GPU 可采样的区域遮罩。
class OFFaceRegionMask {
    /// 遮罩边长；关键点是归一化坐标，正方形即可。128 对脸轮廓够用，比 256 少 4 倍填充。
    static let size = 128
    /// RGBA8888，每像素 4 字节
    private let bytesPerPixel = 4
    /// CPU 像素；上传到 maskTexture
    private var pixels: [UInt8]
    /// GPU 遮罩纹理，linear 采样做软边
    private(set) var texture: MTLTexture?
    
    /// 创建 CPU 缓冲和 Metal 纹理
    /// - Parameter device: 共享 GPU
    init(device: MTLDevice?) {
        let count = OFFaceRegionMask.size * OFFaceRegionMask.size * 4
        pixels = [UInt8](repeating: 0, count: count)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: OFFaceRegionMask.size,
            height: OFFaceRegionMask.size,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        texture = device?.makeTexture(descriptor: desc)
        if texture == nil {
            DDLogError("beauty mask texture alloc failed")
        }
    }
    
    /// 用一张脸的关键点重绘遮罩并上传 GPU
    /// - Parameter face: 归一化点，至少 468 个
    /// - Returns: 是否画成功
    @discardableResult
    func update(face: [CGPoint]) -> Bool {
        guard face.count >= 468, texture != nil else {
            return false
        }
        // 1. memset 清屏，避免 Swift 逐字节循环
        pixels.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                memset(base, 0, raw.count)
            }
        }
        let w = OFFaceRegionMask.size
        let h = OFFaceRegionMask.size
        pixels.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else {
                return
            }
            // 2. FACE_OVAL 上沿到不了发际线，沿下巴→顶方向把上半轮廓顶出去再填皮肤
            fillPolygon(Self.faceOval(from: face), width: w, height: h, rgba: base, channel: 0, value: 255, clearChannel: nil)
            // 3. 眉毛从皮肤抠掉，避免磨皮糊成一条
            fillPolygon(Self.leftBrow(from: face), width: w, height: h, rgba: base, channel: 0, value: 0, clearChannel: nil)
            fillPolygon(Self.rightBrow(from: face), width: w, height: h, rgba: base, channel: 0, value: 0, clearChannel: nil)
            // 4. 亮眼用关键点眼裂填 G，不从皮肤挖洞，眼皮仍走磨皮/美白
            fillPolygon(Self.leftEyeOpening(from: face), width: w, height: h, rgba: base, channel: 1, value: 255, clearChannel: nil)
            fillPolygon(Self.rightEyeOpening(from: face), width: w, height: h, rgba: base, channel: 1, value: 255, clearChannel: nil)
            // 5. 外唇从皮肤抠掉
            fillPolygon(Self.outerLips(from: face), width: w, height: h, rgba: base, channel: 0, value: 0, clearChannel: nil)
            // 6. 内唇是口腔区域，牙齿/舌头靠 shader 按颜色分；开口略放宽以免几乎看不见
            if Self.mouthOpenAmount(face) > 0.005 {
                fillPolygon(Self.innerLips(from: face), width: w, height: h, rgba: base, channel: 2, value: 255, clearChannel: 0)
            }
        }
        upload()
        return true
    }
    
    /// 把 CPU 像素写进 MTLTexture
    private func upload() {
        let w = OFFaceRegionMask.size
        let region = MTLRegionMake2D(0, 0, w, w)
        texture?.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * bytesPerPixel)
    }
    
    /// MediaPipe 脸轮廓。478 点没有发际线，10 号只在额中偏下，上沿要外扩才盖住额头。
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func faceOval(from face: [CGPoint]) -> [CGPoint] {
        let oval = loop([
            10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288,
            397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
            172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109
        ], face: face)
        return extendForehead(oval, face: face)
    }
    
    /// 把轮廓上半段沿下巴→额顶方向顶出发际线附近。下颌不动。
    /// - Parameters:
    ///   - oval: FACE_OVAL 顶点
    ///   - face: 全脸点，用 10 / 152 当轴
    /// - Returns: 额头加高后的多边形
    private static func extendForehead(_ oval: [CGPoint], face: [CGPoint]) -> [CGPoint] {
        guard face.count > 152, !oval.isEmpty else {
            return oval
        }
        let chin = face[152]
        let top = face[10]
        let dx = top.x - chin.x
        let dy = top.y - chin.y
        let faceH = hypot(dx, dy)
        guard faceH > 0.02 else {
            return oval
        }
        let ux = dx / faceH
        let uy = dy / faceH
        return oval.map { point in
            let t = ((point.x - chin.x) * ux + (point.y - chin.y) * uy) / faceH
            let w = max(0, min(1, (t - 0.50) / 0.50))
            let extra = faceH * 0.28 * w * w
            return CGPoint(
                x: min(1, max(0, point.x + ux * extra)),
                y: min(1, max(0, point.y + uy * extra))
            )
        }
    }
    
    /// 左眼裂：MediaPipe 眼轮廓，眼皮不在多边形内
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func leftEyeOpening(from face: [CGPoint]) -> [CGPoint] {
        return loop([33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246], face: face)
    }
    
    /// 右眼裂：MediaPipe 眼轮廓
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func rightEyeOpening(from face: [CGPoint]) -> [CGPoint] {
        return loop([362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398], face: face)
    }
    
    /// 外唇，用来从皮肤抠嘴
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func outerLips(from face: [CGPoint]) -> [CGPoint] {
        return loop([61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185], face: face)
    }
    
    /// 内唇，近似牙齿区域
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func innerLips(from face: [CGPoint]) -> [CGPoint] {
        return loop([78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191], face: face)
    }
    
    /// 左眉轮廓，从皮肤抠洞
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func leftBrow(from face: [CGPoint]) -> [CGPoint] {
        return loop([70, 63, 105, 66, 107, 55, 65, 52, 53, 46], face: face)
    }
    
    /// 右眉轮廓
    /// - Parameter face: 全脸点
    /// - Returns: 归一化多边形
    private static func rightBrow(from face: [CGPoint]) -> [CGPoint] {
        return loop([300, 293, 334, 296, 336, 285, 295, 282, 283, 276], face: face)
    }
    
    /// 478 点里的虹膜（468…477），与区域学生虹膜热力图同一组下标
    /// - Parameter face: 全脸点
    /// - Returns: 最多 10 个虹膜点
    private static func iris(from face: [CGPoint]) -> [CGPoint] {
        return loop([468, 469, 470, 471, 472, 473, 474, 475, 476, 477], face: face)
    }
    
    /// 上下内唇中点距离，用来判断是否张嘴
    /// - Parameter face: 全脸点
    /// - Returns: 归一化开口高度
    private static func mouthOpenAmount(_ face: [CGPoint]) -> CGFloat {
        guard face.count > 14 else {
            return 0
        }
        return abs(face[14].y - face[13].y)
    }
    
    /// 在指定通道叠高斯斑，对齐 composeLandmarkHeatmaps 的 sigma≈0.018×边长
    /// - Parameters:
    ///   - points: 归一化点
    ///   - width: 纹理宽
    ///   - height: 纹理高
    ///   - rgba: 像素基址
    ///   - channel: 0/1/2
    private func splatGaussian(_ points: [CGPoint], width: Int, height: Int, rgba: UnsafeMutablePointer<UInt8>, channel: Int) {
        let sigma = max(1.2, Float(width) * 0.018)
        let radius = Int(ceil(Double(sigma * 4)))
        let denom = 2 * sigma * sigma
        for point in points {
            let cx = Float(point.x) * Float(width - 1)
            let cy = Float(point.y) * Float(height - 1)
            let ix = Int(cx)
            let iy = Int(cy)
            let left = max(0, ix - radius)
            let right = min(width - 1, ix + radius)
            let top = max(0, iy - radius)
            let bottom = min(height - 1, iy + radius)
            for y in top...bottom {
                let dy = Float(y) - cy
                for x in left...right {
                    let dx = Float(x) - cx
                    let g = exp(-(dx * dx + dy * dy) / denom)
                    let offset = (y * width + x) * bytesPerPixel + channel
                    let value = min(255, Int(rgba[offset]) + Int(g * 255))
                    rgba[offset] = UInt8(value)
                }
            }
        }
    }
    
    /// 按下标取出多边形顶点，缺索引则跳过该点
    /// - Parameters:
    ///   - indices: MediaPipe 下标
    ///   - face: 全脸点
    /// - Returns: 有效顶点
    private static func loop(_ indices: [Int], face: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(indices.count)
        for index in indices {
            if index >= 0 && index < face.count {
                points.append(face[index])
            }
        }
        return points
    }
    
    /// 奇偶规则扫描线填充；交点用插入排序，避免每行分配 Array
    /// - Parameters:
    ///   - points: 归一化顶点
    ///   - width: 纹理宽
    ///   - height: 纹理高
    ///   - rgba: 像素基址
    ///   - channel: 0/1/2 = R/G/B
    ///   - value: 写入值
    ///   - clearChannel: 同时清掉的通道，皮肤抠洞用
    private func fillPolygon(_ points: [CGPoint], width: Int, height: Int, rgba: UnsafeMutablePointer<UInt8>, channel: Int, value: UInt8, clearChannel: Int?) {
        let n = points.count
        guard n >= 3 else {
            return
        }
        var xs = [Float](repeating: 0, count: n)
        var ys = [Float](repeating: 0, count: n)
        var minY = height
        var maxY = 0
        for i in 0..<n {
            let px = max(0, min(width - 1, Int(points[i].x * CGFloat(width - 1))))
            let py = max(0, min(height - 1, Int(points[i].y * CGFloat(height - 1))))
            xs[i] = Float(px)
            ys[i] = Float(py)
            minY = min(minY, py)
            maxY = max(maxY, py)
        }
        var nodes = [Int](repeating: 0, count: n)
        for y in minY...maxY {
            var count = 0
            var j = n - 1
            let fy = Float(y)
            for i in 0..<n {
                let yi = ys[i]
                let yj = ys[j]
                if (yi < fy && yj >= fy) || (yj < fy && yi >= fy) {
                    let x = Int(xs[i] + (fy - yi) / (yj - yi) * (xs[j] - xs[i]))
                    nodes[count] = x
                    count += 1
                }
                j = i
            }
            // 插入排序，交点通常只有 2 个
            var a = 1
            while a < count {
                let key = nodes[a]
                var b = a - 1
                while b >= 0 && nodes[b] > key {
                    nodes[b + 1] = nodes[b]
                    b -= 1
                }
                nodes[b + 1] = key
                a += 1
            }
            var k = 0
            while k + 1 < count {
                let x0 = max(0, nodes[k])
                let x1 = min(width - 1, nodes[k + 1])
                if x0 <= x1 {
                    for x in x0...x1 {
                        let offset = (y * width + x) * bytesPerPixel
                        rgba[offset + channel] = value
                        if let clear = clearChannel {
                            rgba[offset + clear] = 0
                        }
                    }
                }
                k += 2
            }
        }
    }
}

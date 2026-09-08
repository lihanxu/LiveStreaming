//
//  AlbumEditSession.swift
//  LiveStreaming
//
//  相册编辑会话（方案 B）：串行 GPU 队列承载全部 inputFrame，导出时独占 tools。
//

import AVFoundation
import UIKit
import OFFilterKit

/// 相册编辑会话：预览与导出共用一份 `OFAuxiliaryTools`，但 never 并发访问。
class AlbumEditSession {
    /// 滤镜门面；设置页绑定此实例
    let tools: OFAuxiliaryTools
    /// 画幅 + 时间线；预览/导出只读
    var document = AlbumEditDocument()
    /// 所有 Metal / MediaPipe 处理必须在此串行队列执行
    private let processingQueue = DispatchQueue(label: "com.oldface.LiveStreaming.album.gpu", qos: .userInitiated)
    /// 导出中为 true 时丢弃预览帧
    private var isExporting = false

    /// 创建独立处理图实例，与直播页参数隔离
    init() {
        tools = OFAuxiliaryTools()
    }

    /// 进入导出独占：排空队列中旧任务后再回调主线程
    /// - Parameter completion: 主线程；可安全停 SCGLView / AVPlayer
    func beginExport(completion: @escaping () -> Void) {
        processingQueue.async {
            self.isExporting = true
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// 退出导出独占
    /// - Parameter completion: 主线程；可恢复 SCGLView / AVPlayer
    func endExport(completion: @escaping () -> Void) {
        processingQueue.async {
            self.isExporting = false
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// 照片：几何后再跑处理图，结果回主线程送预览
    /// - Parameters:
    ///   - source: 预览用原始 BGRA（已 bake 朝向）
    ///   - completion: 主线程回调处理后的 VideoFrame
    func reprocessPhotoPreview(source: CVPixelBuffer, completion: @escaping (VideoFrame) -> Void) {
        let geometry = document.geometry
        processingQueue.async {
            guard !self.isExporting else { return }
            guard let processed = self.processPhotoBuffer(source, geometry: geometry) else { return }
            let frame = AlbumMediaConverter.makeVideoFrame(from: processed)
            DispatchQueue.main.async {
                completion(frame)
            }
        }
    }

    /// 视频预览帧：几何（含轨朝向）后再过处理图；主线程只负责送 SCGLView
    /// - Parameters:
    ///   - pixelBuffer: VideoOutput 当前帧（编码朝向）
    ///   - preferredTransform: 视频轨 `preferredTransform`
    ///   - completion: 主线程回调
    func processVideoPreviewFrame(
        _ pixelBuffer: CVPixelBuffer,
        preferredTransform: CGAffineTransform,
        completion: @escaping (VideoFrame) -> Void
    ) {
        let geometry = document.geometry
        processingQueue.async {
            guard !self.isExporting else { return }
            guard let geometried = AlbumGeometryKernel.apply(
                source: pixelBuffer,
                geometry: geometry,
                preferredTransform: preferredTransform,
                pool: self.tools.pixelBufferPool
            ) else {
                return
            }
            let frame = AlbumMediaConverter.makeVideoFrame(from: geometried)
            self.tools.inputFrame(frame)
            DispatchQueue.main.async {
                completion(frame)
            }
        }
    }

    /// 导出照片：须在 beginExport 之后调用；在 processingQueue 上处理
    /// - Parameters:
    ///   - source: 导出分辨率 BGRA
    ///   - completion: 主线程返回 UIImage 或错误
    func exportPhoto(from source: CVPixelBuffer, completion: @escaping (Result<UIImage, Error>) -> Void) {
        let geometry = document.geometry
        processingQueue.async {
            let processed = self.processPhotoBuffer(source, geometry: geometry) ?? source
            guard let image = AlbumMediaConverter.uiImage(from: processed) else {
                DispatchQueue.main.async {
                    completion(.failure(AlbumExportError.processingFailed("图像转换失败")))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(image))
            }
        }
    }

    /// 导出视频：整段或单段收尾；几何 bake 进像素后 Writer transform 为 identity
    /// - Parameters:
    ///   - asset: 相册 AVAsset
    ///   - progress: 主线程进度 0…1
    ///   - completion: 主线程返回临时 mp4 URL
    func exportVideo(
        asset: AVAsset,
        progress: @escaping (Float) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let geometry = document.geometry
        let timeline = document.timeline
        processingQueue.async {
            do {
                let url = try AlbumVideoExporter.exportSynchronously(
                    asset: asset,
                    session: self,
                    geometry: geometry,
                    timeline: timeline,
                    progress: { value in
                        DispatchQueue.main.async {
                            progress(value)
                        }
                    }
                )
                DispatchQueue.main.async {
                    completion(.success(url))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 视频导出一帧：几何 → 缩到 Writer 尺寸 → 滤镜。**必须**在 processingQueue 上调用。
    /// - Parameters:
    ///   - pixelBuffer: Reader 出的编码朝向 BGRA
    ///   - geometry: 导出开始时拍下的画幅
    ///   - preferredTransform: 视频轨朝向
    ///   - targetWidth: Writer 宽
    ///   - targetHeight: Writer 高
    /// - Returns: 处理后 BGRA；失败则尽力返回几何或原帧
    func processVideoFrameSync(
        _ pixelBuffer: CVPixelBuffer,
        geometry: AlbumGeometryEdit,
        preferredTransform: CGAffineTransform,
        targetWidth: Int,
        targetHeight: Int
    ) -> CVPixelBuffer {
        guard let geometried = AlbumGeometryKernel.apply(
            source: pixelBuffer,
            geometry: geometry,
            preferredTransform: preferredTransform,
            pool: tools.pixelBufferPool
        ) else {
            return pixelBuffer
        }
        var working = geometried
        let width = CVPixelBufferGetWidth(working)
        let height = CVPixelBufferGetHeight(working)
        if width != targetWidth || height != targetHeight {
            working = AlbumMediaConverter.scaledPixelBuffer(
                geometried,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                pool: tools.pixelBufferPool
            ) ?? geometried
        }
        let frame = AlbumMediaConverter.makeVideoFrame(from: working)
        tools.inputFrame(frame)
        return frame.pixelBuffer
    }

    /// 照片：几何产出独立 buffer 再进处理图（滤镜会原地改）
    /// - Parameters:
    ///   - pixelBuffer: 原始 BGRA
    ///   - geometry: 调用前在主线程拍下的画幅快照
    /// - Returns: 几何 + 滤镜后的 buffer；失败 nil
    private func processPhotoBuffer(_ pixelBuffer: CVPixelBuffer, geometry: AlbumGeometryEdit) -> CVPixelBuffer? {
        guard let geometried = AlbumGeometryKernel.apply(
            source: pixelBuffer,
            geometry: geometry,
            preferredTransform: .identity,
            pool: tools.pixelBufferPool
        ) else {
            return nil
        }
        let frame = AlbumMediaConverter.makeVideoFrame(from: geometried)
        tools.inputFrame(frame)
        return frame.pixelBuffer
    }
}

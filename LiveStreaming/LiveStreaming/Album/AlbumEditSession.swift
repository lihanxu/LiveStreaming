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
    /// 多段工程；单资源时 `clips.count == 1`
    var project = AlbumProject()
    /// 当前选中 clip 的单片文档；面板与预览只改这一份
    var document: AlbumEditDocument {
        get { project.selectedDocument }
        set { project.selectedDocument = newValue }
    }
    /// 直方图 / 波形累加；不是处理图节点
    private let scopeAnalyzer: AlbumScopeAnalyzer
    /// 所有 Metal / MediaPipe 处理必须在此串行队列执行
    private let processingQueue = DispatchQueue(label: "com.oldface.LiveStreaming.album.gpu", qos: .userInitiated)
    /// 导出中为 true 时丢弃预览帧
    private var isExporting = false

    /// 示波器面板打开时为 true；关闭则预览路径不跑 kernel
    var scopesEnabled: Bool {
        get { scopeAnalyzer.isEnabled }
        set { scopeAnalyzer.isEnabled = newValue }
    }

    /// 波形 Colorize；只影响 Analyzer 是否写 RGB 累加
    var scopeColorize: Bool {
        get { scopeAnalyzer.colorize }
        set { scopeAnalyzer.colorize = newValue }
    }

    /// 创建独立处理图实例，与直播页参数隔离
    init() {
        tools = OFAuxiliaryTools()
        scopeAnalyzer = AlbumScopeAnalyzer(context: tools.context)
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
    ///   - completion: 主线程回调处理后的 VideoFrame；示波器打开时带 snapshot
    func reprocessPhotoPreview(
        source: CVPixelBuffer,
        completion: @escaping (VideoFrame, AlbumScopeSnapshot?) -> Void
    ) {
        let geometry = document.geometry
        processingQueue.async {
            guard !self.isExporting else { return }
            guard let processed = self.processPhotoBuffer(source, geometry: geometry) else { return }
            let frame = AlbumMediaConverter.makeVideoFrame(from: processed)
            let snapshot = self.scopeAnalyzer.analyze(frame: frame, pool: self.tools.pixelBufferPool)
            DispatchQueue.main.async {
                completion(frame, snapshot)
            }
        }
    }

    /// 视频预览帧：几何后再 cover 到工程画布，再过处理图
    /// - Parameters:
    ///   - pixelBuffer: VideoOutput 当前帧（编码朝向）
    ///   - preferredTransform: 当前 clip 视频轨朝向
    ///   - geometry: 当前 clip 画幅
    ///   - canvasWidth: 工程画布宽；0 表示不 cover
    ///   - canvasHeight: 工程画布高
    ///   - completion: 主线程回调；示波器打开时带 snapshot
    func processVideoPreviewFrame(
        _ pixelBuffer: CVPixelBuffer,
        preferredTransform: CGAffineTransform,
        geometry: AlbumGeometryEdit,
        canvasWidth: Int,
        canvasHeight: Int,
        completion: @escaping (VideoFrame, AlbumScopeSnapshot?) -> Void
    ) {
        processVideoPreviewFrame(
            outgoing: pixelBuffer,
            outgoingTransform: preferredTransform,
            outgoingGeometry: geometry,
            incoming: nil,
            incomingTransform: .identity,
            incomingGeometry: AlbumGeometryEdit(),
            transitionKind: .cut,
            progress: 0,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            completion: completion
        )
    }

    /// 视频预览：两路几何贴画布后混叠，再进滤镜
    /// - Parameters:
    ///   - outgoing: 当前段编码朝向帧
    ///   - outgoingTransform: 当前段轨朝向
    ///   - outgoingGeometry: 当前段画幅
    ///   - incoming: 下一段；硬切为 nil
    ///   - incomingTransform: 下一段轨朝向
    ///   - incomingGeometry: 下一段画幅
    ///   - transitionKind: 接缝
    ///   - progress: 0…1
    ///   - canvasWidth: 工程画布宽
    ///   - canvasHeight: 工程画布高
    ///   - completion: 主线程
    func processVideoPreviewFrame(
        outgoing: CVPixelBuffer,
        outgoingTransform: CGAffineTransform,
        outgoingGeometry: AlbumGeometryEdit,
        incoming: CVPixelBuffer?,
        incomingTransform: CGAffineTransform,
        incomingGeometry: AlbumGeometryEdit,
        transitionKind: AlbumTransitionKind,
        progress: Float,
        canvasWidth: Int,
        canvasHeight: Int,
        completion: @escaping (VideoFrame, AlbumScopeSnapshot?) -> Void
    ) {
        processingQueue.async {
            guard !self.isExporting else { return }
            guard let outgoingCanvas = self.canvasBuffer(
                outgoing,
                geometry: outgoingGeometry,
                preferredTransform: outgoingTransform,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            ) else {
                return
            }
            var working = outgoingCanvas
            if let incoming = incoming, transitionKind != .cut, progress > 0.0001 {
                let incomingCanvas = self.canvasBuffer(
                    incoming,
                    geometry: incomingGeometry,
                    preferredTransform: incomingTransform,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight
                )
                working = AlbumTransitionKernel.mix(
                    outgoing: outgoingCanvas,
                    incoming: incomingCanvas,
                    progress: progress,
                    kind: transitionKind,
                    pool: self.tools.pixelBufferPool
                )
            }
            let frame = AlbumMediaConverter.makeVideoFrame(from: working)
            self.tools.inputFrame(frame)
            let snapshot = self.scopeAnalyzer.analyze(frame: frame, pool: self.tools.pixelBufferPool)
            DispatchQueue.main.async {
                completion(frame, snapshot)
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

    /// 导出视频：单片、硬切或多段转场；几何 bake 后 Writer transform 为 identity
    /// - Parameters:
    ///   - assets: 与 `documents` 对齐的片源
    ///   - documents: 各片画幅 + 时间线
    ///   - transitions: 接缝；硬切可空
    ///   - progress: 主线程进度 0…1
    ///   - completion: 主线程返回临时 mp4 URL
    func exportVideo(
        assets: [AVAsset],
        documents: [AlbumEditDocument],
        transitions: [AlbumTransition] = [],
        progress: @escaping (Float) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        processingQueue.async {
            do {
                let url = try AlbumVideoExporter.exportSynchronously(
                    assets: assets,
                    documents: documents,
                    transitions: transitions,
                    session: self,
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
            working = AlbumMediaConverter.coverFitPixelBuffer(
                geometried,
                canvasWidth: targetWidth,
                canvasHeight: targetHeight,
                pool: tools.pixelBufferPool
            ) ?? geometried
        }
        let frame = AlbumMediaConverter.makeVideoFrame(from: working)
        tools.inputFrame(frame)
        return frame.pixelBuffer
    }

    /// 导出一帧只做几何+画布，不过滤镜；转场混叠之后再 `applyFilterSync`。
    /// - Parameters:
    ///   - pixelBuffer: Reader 帧
    ///   - geometry: 该 clip 画幅
    ///   - preferredTransform: 轨朝向
    ///   - targetWidth: 画布宽
    ///   - targetHeight: 画布高
    /// - Returns: 画布 BGRA
    func processCanvasFrameSync(
        _ pixelBuffer: CVPixelBuffer,
        geometry: AlbumGeometryEdit,
        preferredTransform: CGAffineTransform,
        targetWidth: Int,
        targetHeight: Int
    ) -> CVPixelBuffer {
        return canvasBuffer(
            pixelBuffer,
            geometry: geometry,
            preferredTransform: preferredTransform,
            canvasWidth: targetWidth,
            canvasHeight: targetHeight
        ) ?? pixelBuffer
    }

    /// 滤镜图；必须在 processingQueue 上
    /// - Parameter pixelBuffer: 已是成片画布
    /// - Returns: 滤镜后 buffer
    func applyFilterSync(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let frame = AlbumMediaConverter.makeVideoFrame(from: pixelBuffer)
        tools.inputFrame(frame)
        return frame.pixelBuffer
    }

    /// 几何后再按需 cover
    /// - Parameters:
    ///   - pixelBuffer: 编码朝向
    ///   - geometry: 画幅
    ///   - preferredTransform: 轨朝向
    ///   - canvasWidth: 0 表示不 cover
    ///   - canvasHeight: 0 表示不 cover
    /// - Returns: 画布帧
    private func canvasBuffer(
        _ pixelBuffer: CVPixelBuffer,
        geometry: AlbumGeometryEdit,
        preferredTransform: CGAffineTransform,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> CVPixelBuffer? {
        guard let geometried = AlbumGeometryKernel.apply(
            source: pixelBuffer,
            geometry: geometry,
            preferredTransform: preferredTransform,
            pool: tools.pixelBufferPool
        ) else {
            return nil
        }
        var working = geometried
        if canvasWidth > 0, canvasHeight > 0 {
            let width = CVPixelBufferGetWidth(working)
            let height = CVPixelBufferGetHeight(working)
            if width != canvasWidth || height != canvasHeight {
                working = AlbumMediaConverter.coverFitPixelBuffer(
                    geometried,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    pool: tools.pixelBufferPool
                ) ?? geometried
            }
        }
        return working
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

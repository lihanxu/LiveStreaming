//
//  OFFaceLandmarkerComputer.swift
//  LiveStreaming
//
//  MediaPipe Face Landmarker 节点：live stream 异步推理 478 点网格，供美颜底座使用。
//  推理不阻塞采集；预览可用上一帧结果画调试点。
//

import Foundation
import CoreVideo
import UIKit
import MediaPipeTasksVision
import CocoaLumberjack

/// 处理图中的人脸关键点节点。
public class OFFaceLandmarkerComputer: NSObject, OFProcessNode {
    /// 美颜或网格预览打开时才送帧
    public var isEnabled: Bool {
        return inferenceEnabled
    }
    
    /// 是否把帧送进 Face Landmarker
    public var inferenceEnabled = false
    /// 是否在 pixel buffer 上画关键点（验证用）
    public var overlayEnabled = false
    
    /// MediaPipe 任务；模型加载失败时为 nil
    private var landmarker: FaceLandmarker?
    /// 单调递增时间戳（毫秒），live stream 要求严格递增
    private var nextTimestampMs = 0
    /// 上一帧还没回调时不再送帧，避免推理队列堆积把采集线程拖死
    private var inferenceInFlight = false
    /// 保护 latestFaces / inferenceInFlight
    private let lock = NSLock()
    /// 归一化关键点（x/y ∈ [0,1]），每人一张脸
    private var latestFaces: [[CGPoint]] = []
    /// 避免重复刷错误日志
    private var didLogSetupError = false
    
    /// 加载 Bundle 中的 face_landmarker.task 并建成 live stream 任务
    public override init() {
        super.init()
        setupLandmarker()
    }
    
    /// 从 Bundle 创建 FaceLandmarker，委托设为自己
    private func setupLandmarker() {
        guard let modelPath = OFFilterResources.url(forResource: "face_landmarker", withExtension: "task")?.path else {
            DDLogError("face_landmarker.task not found in bundle")
            return
        }
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numFaces = 1
        options.minFaceDetectionConfidence = 0.5
        options.minFacePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.outputFaceBlendshapes = false
        options.faceLandmarkerLiveStreamDelegate = self
        do {
            landmarker = try FaceLandmarker(options: options)
            DDLogInfo("Face Landmarker ready: \(modelPath)")
        } catch {
            DDLogError("create FaceLandmarker failed: \(error)")
        }
    }
    
    /// 送一帧做异步检测。推理未完成时跳过本帧，避免队列堆积。
    /// - Parameter frame: 当前视频帧
    public func process(_ frame: VideoFrame) {
        guard inferenceEnabled else {
            return
        }
        // 1. 上一趟没回来就不送，美颜继续用上一帧点
        lock.lock()
        let busy = inferenceInFlight
        if !busy {
            inferenceInFlight = true
        }
        lock.unlock()
        if busy {
            return
        }
        // 2. 转 MPImage 并异步推理，时间戳必须递增
        if let landmarker = landmarker, let pixelBuffer = frame.pixelBuffer {
            do {
                let image = try MPImage(pixelBuffer: pixelBuffer)
                nextTimestampMs += 33
                try landmarker.detectAsync(image: image, timestampInMilliseconds: nextTimestampMs)
            } catch {
                lock.lock()
                inferenceInFlight = false
                lock.unlock()
                if !didLogSetupError {
                    DDLogError("FaceLandmarker detectAsync failed: \(error)")
                    didLogSetupError = true
                }
            }
        } else {
            lock.lock()
            inferenceInFlight = false
            lock.unlock()
            if landmarker == nil, !didLogSetupError {
                DDLogError("FaceLandmarker is nil, skip inference")
                didLogSetupError = true
            }
        }
    }
    
    /// 在滤镜之后画网格，避免 LUT 把绿点也调色
    /// - Parameter frame: 已处理完的预览帧
    public func applyDebugOverlayIfNeeded(_ frame: VideoFrame) {
        if overlayEnabled {
            drawOverlay(on: frame)
        }
    }
    
    /// 线程安全地取出最近一次人脸点
    /// - Returns: 每张脸一组归一化点
    public func copyLatestFaces() -> [[CGPoint]] {
        lock.lock()
        let faces = latestFaces
        lock.unlock()
        return faces
    }
    
    /// 在 BGRA buffer 上画绿色小点。有 Metal 纹理时清掉，避免预览仍读旧纹理
    /// - Parameter frame: 要画点的帧
    private func drawOverlay(on frame: VideoFrame) {
        let faces = copyLatestFaces()
        guard !faces.isEmpty, let pixelBuffer = frame.pixelBuffer else {
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for face in faces {
            for point in face {
                let px = Int(point.x * CGFloat(width))
                let py = Int(point.y * CGFloat(height))
                paintDot(ptr: ptr, bytesPerRow: bytesPerRow, width: width, height: height, x: px, y: py)
            }
        }
        frame.texture = nil
    }
    
    /// 画 3×3 的 BGRA 绿点
    /// - Parameters:
    ///   - ptr: 像素基址
    ///   - bytesPerRow: 行字节数
    ///   - width: 图像宽
    ///   - height: 图像高
    ///   - x: 中心 x
    ///   - y: 中心 y
    private func paintDot(ptr: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, width: Int, height: Int, x: Int, y: Int) {
        let radius = 1
        for dy in -radius...radius {
            for dx in -radius...radius {
                let xx = x + dx
                let yy = y + dy
                if xx < 0 || yy < 0 || xx >= width || yy >= height {
                    continue
                }
                let offset = yy * bytesPerRow + xx * 4
                ptr[offset] = 0
                ptr[offset + 1] = 255
                ptr[offset + 2] = 0
                ptr[offset + 3] = 255
            }
        }
    }
}

extension OFFaceLandmarkerComputer: FaceLandmarkerLiveStreamDelegate {
    /// live stream 回调：缓存归一化关键点
    public func faceLandmarker(
        _ faceLandmarker: FaceLandmarker,
        didFinishDetection result: FaceLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let error = error {
            DDLogError("FaceLandmarker result error: \(error)")
            lock.lock()
            inferenceInFlight = false
            lock.unlock()
            return
        }
        guard let result = result else {
            lock.lock()
            inferenceInFlight = false
            lock.unlock()
            return
        }
        var faces: [[CGPoint]] = []
        for landmarks in result.faceLandmarks {
            let points = landmarks.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            faces.append(points)
        }
        lock.lock()
        latestFaces = faces
        inferenceInFlight = false
        lock.unlock()
    }
}

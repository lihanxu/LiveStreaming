//
//  AlbumVideoExporter.swift
//  LiveStreaming
//
//  离线导出：Reader 解码 → Session 串行 GPU 处理 → Writer 写 mp4 → 相册。
//

import AVFoundation
import Photos
import CocoaLumberjack

/// 导出失败时的错误域
enum AlbumExportError: LocalizedError {
    /// 找不到视频轨
    case missingVideoTrack
    /// Reader / Writer 初始化失败
    case setupFailed(String)
    /// 读写过程中断
    case processingFailed(String)

    /// 用户可见说明
    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "找不到视频轨道"
        case .setupFailed(let message):
            return message
        case .processingFailed(let message):
            return message
        }
    }
}

/// 相册视频离线导出；须在 `AlbumEditSession` 的 processingQueue 上调用同步方法。
enum AlbumVideoExporter {

    /// 同步导出到临时 mp4（调用方必须在 session GPU 队列）
    /// - Parameters:
    ///   - asset: 源视频
    ///   - session: 编辑会话
    ///   - progress: 进度回调（内部会切主线程）
    /// - Returns: 临时 mp4 URL
    static func exportSynchronously(
        asset: AVAsset,
        session: AlbumEditSession,
        progress: @escaping (Float) -> Void
    ) throws -> URL {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw AlbumExportError.missingVideoTrack
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let absWidth = abs(naturalSize.width)
        let absHeight = abs(naturalSize.height)
        let (outputWidth, outputHeight) = AlbumMediaConverter.scaledSize(
            originalWidth: Int(absWidth),
            originalHeight: Int(absHeight),
            maxLongEdge: AlbumMediaConverter.videoExportMaxLongEdge
        )

        let reader = try AVAssetReader(asset: asset)
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw AlbumExportError.setupFailed("无法添加视频读取输出")
        }
        reader.add(videoReaderOutput)

        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            }
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "album_export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let bitRate = Float(outputWidth * outputHeight * 2 * 32)
        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = videoTrack.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(videoWriterInput) else {
            throw AlbumExportError.setupFailed("无法添加视频写入输入")
        }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if let audioTrack = audioTrack,
           let formatDescription = audioTrack.formatDescriptions.first {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription as! CMFormatDescription
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            }
        }

        guard reader.startReading() else {
            throw AlbumExportError.setupFailed(reader.error?.localizedDescription ?? "读取器启动失败")
        }
        guard writer.startWriting() else {
            throw AlbumExportError.setupFailed(writer.error?.localizedDescription ?? "写入器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.001)
        var videoFinished = false
        var audioFinished = audioWriterInput == nil

        while reader.status == .reading && !(videoFinished && audioFinished) {
            var didWork = false

            if !videoFinished && videoWriterInput.isReadyForMoreMediaData {
                if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                   let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let processedBuffer = session.processPixelBufferSync(
                        imageBuffer,
                        targetWidth: outputWidth,
                        targetHeight: outputHeight
                    )
                    if !adaptor.append(processedBuffer, withPresentationTime: presentationTime) {
                        DDLogError("video append failed: \(writer.error?.localizedDescription ?? "")")
                    }
                    progress(min(1, Float(CMTimeGetSeconds(presentationTime) / durationSeconds)))
                    didWork = true
                } else {
                    videoWriterInput.markAsFinished()
                    videoFinished = true
                }
            }

            if !audioFinished,
               let audioReaderOutput = audioReaderOutput,
               let audioWriterInput = audioWriterInput,
               audioWriterInput.isReadyForMoreMediaData {
                if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
                    if !audioWriterInput.append(sampleBuffer) {
                        DDLogError("audio append failed: \(writer.error?.localizedDescription ?? "")")
                    }
                    didWork = true
                } else {
                    audioWriterInput.markAsFinished()
                    audioFinished = true
                }
            }

            if !didWork {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        if reader.status == .failed {
            throw AlbumExportError.processingFailed(reader.error?.localizedDescription ?? "读取失败")
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AlbumExportError.processingFailed(writer.error?.localizedDescription ?? "写入失败")
        }
        progress(1)
        return outputURL
    }

    /// 将 mp4 保存到系统相册
    static func saveVideoToPhotoLibrary(fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: fileURL) }
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? AlbumExportError.processingFailed("保存到相册失败")))
                }
            }
        })
    }

    /// 将 UIImage 保存到系统相册
    static func savePhotoToPhotoLibrary(image: UIImage, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? AlbumExportError.processingFailed("保存到相册失败")))
                }
            }
        })
    }
}

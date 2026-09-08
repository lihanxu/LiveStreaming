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
        // 用编码尺寸而不是 transform 后的显示尺寸，避免和 writer.transform 叠两次
        let codedWidth = max(2, Int(videoTrack.naturalSize.width.rounded()))
        let codedHeight = max(2, Int(videoTrack.naturalSize.height.rounded()))
        let scaled = AlbumMediaConverter.scaledSize(
            originalWidth: codedWidth,
            originalHeight: codedHeight,
            maxLongEdge: AlbumMediaConverter.videoExportMaxLongEdge
        )
        let (outputWidth, outputHeight) = AlbumMediaConverter.evenSize(width: scaled.0, height: scaled.1)
        DDLogInfo("album export start \(codedWidth)x\(codedHeight) -> \(outputWidth)x\(outputHeight) duration=\(CMTimeGetSeconds(asset.duration))")

        let reader = try AVAssetReader(asset: asset)
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        videoReaderOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoReaderOutput) else {
            throw AlbumExportError.setupFailed("无法添加视频读取输出")
        }
        reader.add(videoReaderOutput)

        let audioTrack = asset.tracks(withMediaType: .audio).first
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            } else {
                DDLogError("album export skip audio: cannot add PCM reader")
            }
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "album_export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let bitRate = min(8_000_000, outputWidth * outputHeight * 6)
        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
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
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
        guard writer.canAdd(videoWriterInput) else {
            throw AlbumExportError.setupFailed("无法添加视频写入输入")
        }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            } else {
                DDLogError("album export skip audio: cannot add AAC writer")
                audioReaderOutput = nil
            }
        }

        guard reader.startReading() else {
            let message = reader.error?.localizedDescription ?? "读取器启动失败"
            DDLogError("album export reader start failed: \(message)")
            throw AlbumExportError.setupFailed(message)
        }
        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "写入器启动失败"
            DDLogError("album export writer start failed: \(message)")
            throw AlbumExportError.setupFailed(message)
        }

        let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.001)
        var sessionStarted = false
        var videoFinished = false
        var audioFinished = audioWriterInput == nil
        var frameIndex = 0

        while reader.status == .reading && !(videoFinished && audioFinished) {
            var didWork = false

            if !videoFinished && videoWriterInput.isReadyForMoreMediaData {
                if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(),
                   let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    if !sessionStarted {
                        writer.startSession(atSourceTime: presentationTime)
                        sessionStarted = true
                        DDLogInfo("album export session at \(CMTimeGetSeconds(presentationTime))")
                    }
                    autoreleasepool {
                        let processedBuffer = session.processPixelBufferSync(
                            imageBuffer,
                            targetWidth: outputWidth,
                            targetHeight: outputHeight
                        )
                        let ok = adaptor.append(processedBuffer, withPresentationTime: presentationTime)
                        if !ok {
                            DDLogError("album export video append failed: \(writer.error?.localizedDescription ?? "unknown") status=\(writer.status.rawValue)")
                        }
                    }
                    frameIndex += 1
                    if frameIndex == 1 || frameIndex % 30 == 0 {
                        DDLogInfo("album export frame \(frameIndex) t=\(CMTimeGetSeconds(presentationTime))")
                    }
                    progress(min(1, Float(CMTimeGetSeconds(presentationTime) / durationSeconds)))
                    didWork = true
                } else {
                    videoWriterInput.markAsFinished()
                    videoFinished = true
                    DDLogInfo("album export video finished frames=\(frameIndex)")
                }
            }

            if !audioFinished,
               let audioReaderOutput = audioReaderOutput,
               let audioWriterInput = audioWriterInput,
               audioWriterInput.isReadyForMoreMediaData {
                if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
                    if sessionStarted {
                        if !audioWriterInput.append(sampleBuffer) {
                            DDLogError("album export audio append failed: \(writer.error?.localizedDescription ?? "")")
                        }
                    }
                    didWork = true
                } else {
                    audioWriterInput.markAsFinished()
                    audioFinished = true
                    DDLogInfo("album export audio finished")
                }
            }

            if writer.status == .failed {
                throw AlbumExportError.processingFailed(writer.error?.localizedDescription ?? "写入失败")
            }

            if !didWork {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        if !sessionStarted {
            throw AlbumExportError.processingFailed("没有可读的视频帧")
        }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "读取失败"
            DDLogError("album export reader failed: \(message)")
            throw AlbumExportError.processingFailed(message)
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            let message = writer.error?.localizedDescription ?? "写入失败"
            DDLogError("album export writer not completed: \(message) status=\(writer.status.rawValue)")
            throw AlbumExportError.processingFailed(message)
        }
        DDLogInfo("album export mp4 ready \(outputURL.lastPathComponent)")
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
                    DDLogInfo("album export saved to photo library")
                    completion(.success(()))
                } else {
                    DDLogError("album export save video failed: \(error?.localizedDescription ?? "")")
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

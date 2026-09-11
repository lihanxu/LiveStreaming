//
//  AlbumVideoExporter.swift
//  LiveStreaming
//
//  离线导出：Reader 解码 → 几何 → Session 串行 GPU 处理 → Writer 写 mp4 → 相册。
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
    ///   - assets: 与 documents 对齐的片源
    ///   - documents: 各片画幅 + 时间线
    ///   - transitions: 接缝
    ///   - session: 编辑会话
    ///   - progress: 进度回调（内部会切主线程）
    /// - Returns: 临时 mp4 URL
    static func exportSynchronously(
        assets: [AVAsset],
        documents: [AlbumEditDocument],
        transitions: [AlbumTransition] = [],
        session: AlbumEditSession,
        progress: @escaping (Float) -> Void
    ) throws -> URL {
        guard assets.count == documents.count, let firstAsset = assets.first else {
            throw AlbumExportError.missingVideoTrack
        }
        guard let videoTrack = firstAsset.tracks(withMediaType: .video).first else {
            throw AlbumExportError.missingVideoTrack
        }
        let codedWidth = max(2, Int(videoTrack.naturalSize.width.rounded()))
        let codedHeight = max(2, Int(videoTrack.naturalSize.height.rounded()))
        let firstGeometry = documents[0].geometry
        let firstTransform = videoTrack.preferredTransform
        let geometrySize = AlbumGeometryKernel.outputPixelSize(
            sourceWidth: codedWidth,
            sourceHeight: codedHeight,
            geometry: firstGeometry,
            preferredTransform: firstTransform
        )
        let scaled = AlbumMediaConverter.scaledSize(
            originalWidth: geometrySize.0,
            originalHeight: geometrySize.1,
            maxLongEdge: AlbumMediaConverter.videoExportMaxLongEdge
        )
        let (outputWidth, outputHeight) = AlbumMediaConverter.evenSize(width: scaled.0, height: scaled.1)
        let clipTransforms = assets.map { asset -> CGAffineTransform in
            asset.tracks(withMediaType: .video).first?.preferredTransform ?? .identity
        }
        let projectMapper = AlbumProjectMapper(
            assets: assets,
            documents: documents,
            transitions: transitions
        )
        if projectMapper.hasOverlap {
            return try exportWithTransitions(
                assets: assets,
                documents: documents,
                clipTransforms: clipTransforms,
                projectMapper: projectMapper,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                geometrySize: geometrySize,
                session: session,
                progress: progress
            )
        }
        let readAsset: AVAsset
        var timeRange: CMTimeRange
        if projectMapper.needsComposition, let composition = projectMapper.makeComposition() {
            readAsset = composition
            timeRange = CMTimeRange(start: .zero, duration: projectMapper.playDuration)
        } else {
            let mapper = AlbumTimeMapper(timeline: documents[0].timeline, sourceDuration: firstAsset.duration)
            readAsset = mapper.exportSource(from: firstAsset)
            timeRange = mapper.exportTimeRange()
            if !mapper.needsComposition {
                timeRange = timeRange.intersection(CMTimeRange(start: .zero, duration: firstAsset.duration))
            }
            if !timeRange.duration.isValid || CMTimeGetSeconds(timeRange.duration) < 0.05 {
                timeRange = CMTimeRange(
                    start: .zero,
                    duration: mapper.needsComposition ? mapper.playDuration : firstAsset.duration
                )
            }
        }
        guard let readVideoTrack = readAsset.tracks(withMediaType: .video).first else {
            throw AlbumExportError.missingVideoTrack
        }
        DDLogInfo(
            "album export start clips=\(assets.count) geo=\(geometrySize.0)x\(geometrySize.1) -> \(outputWidth)x\(outputHeight) range=\(CMTimeGetSeconds(timeRange.start))-\(CMTimeGetSeconds(timeRange.end)) multi=\(projectMapper.needsComposition) play=\(CMTimeGetSeconds(projectMapper.playDuration))"
        )

        let reader = try AVAssetReader(asset: readAsset)
        reader.timeRange = timeRange
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(track: readVideoTrack, outputSettings: videoReaderSettings)
        videoReaderOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoReaderOutput) else {
            throw AlbumExportError.setupFailed("无法添加视频读取输出")
        }
        reader.add(videoReaderOutput)

        let audioTrack = readAsset.tracks(withMediaType: .audio).first
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings())
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
        let videoWriterInput = makeVideoWriterInput(width: outputWidth, height: outputHeight)
        let adaptor = makeVideoAdaptor(input: videoWriterInput, width: outputWidth, height: outputHeight)
        guard writer.canAdd(videoWriterInput) else {
            throw AlbumExportError.setupFailed("无法添加视频写入输入")
        }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            if let input = makeAudioWriterInput(), writer.canAdd(input) {
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

        let durationSeconds = max(CMTimeGetSeconds(timeRange.duration), 0.001)
        let trimStart = timeRange.start
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
                        let playTime = CMTimeSubtract(presentationTime, trimStart)
                        let clipIndex = projectMapper.contribution(at: playTime)?.clipIndex ?? 0
                        let processedBuffer = session.processVideoFrameSync(
                            imageBuffer,
                            geometry: documents[clipIndex].geometry,
                            preferredTransform: clipTransforms[clipIndex],
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
                    let elapsedSeconds = max(0.0, CMTimeGetSeconds(CMTimeSubtract(presentationTime, trimStart)))
                    progress(min(1.0, Float(elapsedSeconds / durationSeconds)))
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

    /// PCM 读出设置
    /// - Returns: 44.1kHz 立体声 16bit
    private static func pcmSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    /// H.264 Writer 输入
    /// - Parameters:
    ///   - width: 偶数宽
    ///   - height: 偶数高
    /// - Returns: 视频输入
    private static func makeVideoWriterInput(width: Int, height: Int) -> AVAssetWriterInput {
        let bitRate = min(8_000_000, width * height * 6)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = .identity
        return input
    }

    /// 像素 adaptor
    /// - Parameters:
    ///   - input: 视频 Writer
    ///   - width: 宽
    ///   - height: 高
    /// - Returns: adaptor
    private static func makeVideoAdaptor(
        input: AVAssetWriterInput,
        width: Int,
        height: Int
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
    }

    /// AAC Writer
    /// - Returns: 音频输入
    private static func makeAudioWriterInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// 有重叠时：工程轴定帧，每 clip 一路 Reader，几何后混叠再滤镜。
    /// - Parameters:
    ///   - assets: 片源
    ///   - documents: 文档
    ///   - clipTransforms: 各轨朝向
    ///   - projectMapper: 工程时钟
    ///   - outputWidth: Writer 宽
    ///   - outputHeight: Writer 高
    ///   - geometrySize: 几何尺寸（日志）
    ///   - session: GPU 会话
    ///   - progress: 进度
    /// - Returns: 临时 mp4
    private static func exportWithTransitions(
        assets: [AVAsset],
        documents: [AlbumEditDocument],
        clipTransforms: [CGAffineTransform],
        projectMapper: AlbumProjectMapper,
        outputWidth: Int,
        outputHeight: Int,
        geometrySize: (Int, Int),
        session: AlbumEditSession,
        progress: @escaping (Float) -> Void
    ) throws -> URL {
        var pullers: [AlbumClipFramePuller] = []
        for (asset, document) in zip(assets, documents) {
            let mapper = AlbumTimeMapper(timeline: document.timeline, sourceDuration: asset.duration)
            let puller = try AlbumClipFramePuller(asset: asset, mapper: mapper)
            pullers.append(puller)
        }
        DDLogInfo(
            "album export overlap clips=\(assets.count) geo=\(geometrySize.0)x\(geometrySize.1) -> \(outputWidth)x\(outputHeight) play=\(CMTimeGetSeconds(projectMapper.playDuration))"
        )

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "album_export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoWriterInput = makeVideoWriterInput(width: outputWidth, height: outputHeight)
        let adaptor = makeVideoAdaptor(input: videoWriterInput, width: outputWidth, height: outputHeight)
        guard writer.canAdd(videoWriterInput) else {
            throw AlbumExportError.setupFailed("无法添加视频写入输入")
        }
        writer.add(videoWriterInput)

        var audioReader: AVAssetReader?
        var audioMixOutput: AVAssetReaderAudioMixOutput?
        var audioWriterInput: AVAssetWriterInput?
        if let (audioComposition, audioMix) = projectMapper.makeOverlappingAudioMix() {
            let reader = try AVAssetReader(asset: audioComposition)
            reader.timeRange = CMTimeRange(start: .zero, duration: projectMapper.playDuration)
            let mixOutput = AVAssetReaderAudioMixOutput(
                audioTracks: audioComposition.tracks(withMediaType: .audio),
                audioSettings: pcmSettings()
            )
            mixOutput.audioMix = audioMix
            mixOutput.alwaysCopiesSampleData = false
            if reader.canAdd(mixOutput), let input = makeAudioWriterInput(), writer.canAdd(input) {
                reader.add(mixOutput)
                writer.add(input)
                audioReader = reader
                audioMixOutput = mixOutput
                audioWriterInput = input
            }
        }

        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "写入器启动失败"
            throw AlbumExportError.setupFailed(message)
        }
        if let audioReader = audioReader {
            guard audioReader.startReading() else {
                throw AlbumExportError.setupFailed(audioReader.error?.localizedDescription ?? "音频读取失败")
            }
        }
        writer.startSession(atSourceTime: .zero)

        let playDuration = projectMapper.playDuration
        let durationSeconds = max(CMTimeGetSeconds(playDuration), 0.001)
        let fps = exportFrameRate(from: assets.first)
        let frameDuration = CMTime(seconds: 1.0 / Double(fps), preferredTimescale: 600)
        var presentationTime = CMTime.zero
        var frameIndex = 0
        var videoFinished = false
        var audioFinished = audioWriterInput == nil

        while !(videoFinished && audioFinished) {
            var didWork = false
            if !videoFinished && videoWriterInput.isReadyForMoreMediaData {
                if CMTimeCompare(presentationTime, playDuration) < 0 {
                    autoreleasepool {
                        let plan = projectMapper.framePlan(at: presentationTime)
                        guard let plan = plan,
                              pullers.indices.contains(plan.outgoing.clipIndex),
                              let outgoingBuffer = pullers[plan.outgoing.clipIndex].pixelBuffer(
                                atClipPlayTime: plan.outgoing.clipPlayTime
                              ) else {
                            return
                        }
                        let outgoingCanvas = session.processCanvasFrameSync(
                            outgoingBuffer,
                            geometry: documents[plan.outgoing.clipIndex].geometry,
                            preferredTransform: clipTransforms[plan.outgoing.clipIndex],
                            targetWidth: outputWidth,
                            targetHeight: outputHeight
                        )
                        var mixed = outgoingCanvas
                        if let incoming = plan.incoming,
                           pullers.indices.contains(incoming.clipIndex),
                           let incomingBuffer = pullers[incoming.clipIndex].pixelBuffer(
                            atClipPlayTime: incoming.clipPlayTime
                           ) {
                            let incomingCanvas = session.processCanvasFrameSync(
                                incomingBuffer,
                                geometry: documents[incoming.clipIndex].geometry,
                                preferredTransform: clipTransforms[incoming.clipIndex],
                                targetWidth: outputWidth,
                                targetHeight: outputHeight
                            )
                            mixed = AlbumTransitionKernel.mix(
                                outgoing: outgoingCanvas,
                                incoming: incomingCanvas,
                                progress: plan.progress,
                                kind: plan.kind,
                                pool: session.tools.pixelBufferPool
                            )
                        }
                        let filtered = session.applyFilterSync(mixed)
                        if !adaptor.append(filtered, withPresentationTime: presentationTime) {
                            DDLogError("album export overlap append failed: \(writer.error?.localizedDescription ?? "")")
                        }
                    }
                    frameIndex += 1
                    if frameIndex == 1 || frameIndex % 30 == 0 {
                        DDLogInfo("album export overlap frame \(frameIndex) t=\(CMTimeGetSeconds(presentationTime))")
                    }
                    progress(min(1.0, Float(CMTimeGetSeconds(presentationTime) / durationSeconds)))
                    presentationTime = CMTimeAdd(presentationTime, frameDuration)
                    didWork = true
                } else {
                    videoWriterInput.markAsFinished()
                    videoFinished = true
                    DDLogInfo("album export overlap video finished frames=\(frameIndex)")
                    didWork = true
                }
            }

            if !audioFinished,
               let audioMixOutput = audioMixOutput,
               let audioWriterInput = audioWriterInput,
               audioWriterInput.isReadyForMoreMediaData {
                if let sampleBuffer = audioMixOutput.copyNextSampleBuffer() {
                    if !audioWriterInput.append(sampleBuffer) {
                        DDLogError("album export overlap audio append failed")
                    }
                    didWork = true
                } else {
                    audioWriterInput.markAsFinished()
                    audioFinished = true
                    didWork = true
                }
            }

            if writer.status == .failed {
                throw AlbumExportError.processingFailed(writer.error?.localizedDescription ?? "写入失败")
            }
            if !didWork {
                Thread.sleep(forTimeInterval: 0.005)
            }
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

    /// 导出帧率：跟第一段，夹到 24…30
    /// - Parameter asset: 第一段
    /// - Returns: fps
    private static func exportFrameRate(from asset: AVAsset?) -> Float {
        let rate = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        if rate < 24 {
            return 24
        }
        if rate > 30 {
            return 30
        }
        return rate
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

/// 按 clip 播放轴顺序拉帧；时间只向前。
private final class AlbumClipFramePuller {
    /// 该片 TimeMapper
    private let mapper: AlbumTimeMapper
    /// 解码器
    private let reader: AVAssetReader
    /// 视频输出
    private let output: AVAssetReaderTrackOutput
    /// 最近一帧
    private var currentBuffer: CVPixelBuffer?
    /// 最近一帧 PTS（读出资源时间）
    private var currentTime = CMTime.invalid

    /// 打开该 clip 的导出源
    /// - Parameters:
    ///   - asset: 原片
    ///   - mapper: 时间线
    init(asset: AVAsset, mapper: AlbumTimeMapper) throws {
        self.mapper = mapper
        let source = mapper.exportSource(from: asset)
        guard let track = source.tracks(withMediaType: .video).first else {
            throw AlbumExportError.missingVideoTrack
        }
        let reader = try AVAssetReader(asset: source)
        reader.timeRange = mapper.exportTimeRange()
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw AlbumExportError.setupFailed("无法添加片段读取输出")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AlbumExportError.setupFailed(reader.error?.localizedDescription ?? "片段读取失败")
        }
        self.reader = reader
        self.output = output
    }

    /// 拉到不早于 clip 播放时间的一帧
    /// - Parameter clipPlayTime: 该 clip 播放轴
    /// - Returns: 编码朝向 BGRA
    func pixelBuffer(atClipPlayTime clipPlayTime: CMTime) -> CVPixelBuffer? {
        let target: CMTime
        if mapper.needsComposition {
            target = clipPlayTime
        } else {
            target = CMTimeAdd(mapper.exportTimeRange().start, clipPlayTime)
        }
        while true {
            if currentTime.isValid, CMTimeCompare(currentTime, target) >= 0 {
                return currentBuffer
            }
            guard let sample = output.copyNextSampleBuffer(),
                  let image = CMSampleBufferGetImageBuffer(sample) else {
                return currentBuffer
            }
            currentBuffer = image
            currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
        }
    }
}


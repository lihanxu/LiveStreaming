//
//  AlbumTimeMapper.swift
//  LiveStreaming
//
//  时间线映射：源时间 ↔ 播放轴、拼 AVMutableComposition。不处理像素。
//

import AVFoundation
import CoreMedia

/// 一份时间线在给定源时长下的只读视图；预览 Composition 与导出 PTS 共用。
struct AlbumTimeMapper {
    /// 源媒体时长
    let sourceDuration: CMTime
    /// 已排序、不相交的保留段（speed 已夹紧）
    let segments: [AlbumTimelineSegment]

    /// 从文档解析保留段
    /// - Parameters:
    ///   - timeline: 剪辑文档时间线
    ///   - sourceDuration: 源时长
    init(timeline: AlbumTimelineEdit, sourceDuration: CMTime) {
        self.sourceDuration = sourceDuration
        self.segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
    }

    /// 播放轴总长 = Σ(段源时长 / speed)
    var playDuration: CMTime {
        return segments.reduce(CMTime.zero) { partial, segment in
            CMTimeAdd(partial, Self.playDuration(of: segment))
        }
    }

    /// 多段或任一非 1x 才需要 Composition；单段 1x 仍用原片 + 收尾
    var needsComposition: Bool {
        if segments.count >= 2 {
            return true
        }
        return segments.contains { !AlbumTimelineEdit.isUnitySpeed($0.speed) }
    }

    /// 把源 PTS 映射到播放轴；须属于该段。阶段 4 起除以 speed。
    /// - Parameters:
    ///   - sourceTime: 该段内的源时间
    ///   - segment: 当前段
    ///   - playOffset: 该段在播放轴上的起点
    /// - Returns: 从 0 起算的播放时间
    func playTime(sourceTime: CMTime, in segment: AlbumTimelineSegment, playOffset: CMTime) -> CMTime {
        let local = CMTimeMaximum(CMTimeSubtract(sourceTime, segment.sourceStart), .zero)
        let scaled = CMTimeMultiplyByFloat64(local, multiplier: 1.0 / AlbumTimelineEdit.clampedSpeed(segment.speed))
        return CMTimeAdd(playOffset, scaled)
    }

    /// 播放轴逆映射回源时间：`start + (play − offset) × speed`
    /// - Parameters:
    ///   - playTime: 播放轴时间
    ///   - segment: 当前段
    ///   - playOffset: 该段在播放轴上的起点
    /// - Returns: 源媒体时间
    func sourceTime(playTime: CMTime, in segment: AlbumTimelineSegment, playOffset: CMTime) -> CMTime {
        let localPlay = CMTimeMaximum(CMTimeSubtract(playTime, playOffset), .zero)
        let sourceLocal = CMTimeMultiplyByFloat64(localPlay, multiplier: AlbumTimelineEdit.clampedSpeed(segment.speed))
        return CMTimeAdd(segment.sourceStart, sourceLocal)
    }

    /// 按保留段顺序插入源轨，再按 1/speed 缩放，播放轴无缺口。
    /// - Parameter asset: 相册原片
    /// - Returns: 可交给 AVPlayer 的合成；失败 nil
    func makeComposition(from asset: AVAsset) -> AVMutableComposition? {
        guard needsComposition else { return nil }
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        var audioComp: AVMutableCompositionTrack?
        if audioTrack != nil {
            audioComp = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        var cursor = CMTime.zero
        do {
            for segment in segments {
                let range = CMTimeRange(start: segment.sourceStart, end: segment.sourceEnd)
                guard range.duration.isValid, CMTimeGetSeconds(range.duration) >= 0.05 else { continue }
                let speed = AlbumTimelineEdit.clampedSpeed(segment.speed)
                let playDur = Self.playDuration(of: segment)
                try videoComp.insertTimeRange(range, of: videoTrack, at: cursor)
                var audioInsertedRange: CMTimeRange?
                var audioAt = cursor
                if let audioTrack = audioTrack, let audioComp = audioComp {
                    let audioRange = range.intersection(audioTrack.timeRange)
                    if audioRange.duration.isValid, CMTimeGetSeconds(audioRange.duration) >= 0.05 {
                        audioAt = CMTimeAdd(cursor, CMTimeSubtract(audioRange.start, range.start))
                        try audioComp.insertTimeRange(audioRange, of: audioTrack, at: audioAt)
                        audioInsertedRange = audioRange
                    }
                }
                // 先 insert 再 scale；音视频同一倍率（第一期变调）
                if !AlbumTimelineEdit.isUnitySpeed(speed) {
                    videoComp.scaleTimeRange(
                        CMTimeRange(start: cursor, duration: range.duration),
                        toDuration: playDur
                    )
                    if let audioComp = audioComp, let audioInsertedRange = audioInsertedRange {
                        let audioPlay = CMTimeMultiplyByFloat64(
                            audioInsertedRange.duration,
                            multiplier: 1.0 / speed
                        )
                        audioComp.scaleTimeRange(
                            CMTimeRange(start: audioAt, duration: audioInsertedRange.duration),
                            toDuration: audioPlay
                        )
                    }
                }
                cursor = CMTimeAdd(cursor, playDur)
            }
        } catch {
            return nil
        }
        videoComp.preferredTransform = videoTrack.preferredTransform
        guard cursor.isValid, CMTimeCompare(cursor, .zero) > 0 else { return nil }
        return composition
    }

    /// 把本时间线的保留段插到已有合成轴 `at`，供多文件硬切。始终 insert（含单段 1x）。
    /// - Parameters:
    ///   - videoComp: 工程视频轨
    ///   - audioComp: 工程音频轨；源无音则可仍插入空隙
    ///   - asset: 本 clip 原片
    ///   - cursor: 插入点（工程播放轴）
    /// - Returns: 插入后的光标；失败 nil
    func append(
        videoComp: AVMutableCompositionTrack,
        audioComp: AVMutableCompositionTrack?,
        from asset: AVAsset,
        at cursor: CMTime
    ) -> CMTime? {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        var next = cursor
        do {
            for segment in segments {
                let range = CMTimeRange(start: segment.sourceStart, end: segment.sourceEnd)
                guard range.duration.isValid, CMTimeGetSeconds(range.duration) >= 0.05 else { continue }
                let speed = AlbumTimelineEdit.clampedSpeed(segment.speed)
                let playDur = Self.playDuration(of: segment)
                try videoComp.insertTimeRange(range, of: videoTrack, at: next)
                var audioInsertedRange: CMTimeRange?
                var audioAt = next
                if let audioTrack = audioTrack, let audioComp = audioComp {
                    let audioRange = range.intersection(audioTrack.timeRange)
                    if audioRange.duration.isValid, CMTimeGetSeconds(audioRange.duration) >= 0.05 {
                        audioAt = CMTimeAdd(next, CMTimeSubtract(audioRange.start, range.start))
                        try audioComp.insertTimeRange(audioRange, of: audioTrack, at: audioAt)
                        audioInsertedRange = audioRange
                    }
                }
                if !AlbumTimelineEdit.isUnitySpeed(speed) {
                    videoComp.scaleTimeRange(
                        CMTimeRange(start: next, duration: range.duration),
                        toDuration: playDur
                    )
                    if let audioComp = audioComp, let audioInsertedRange = audioInsertedRange {
                        let audioPlay = CMTimeMultiplyByFloat64(
                            audioInsertedRange.duration,
                            multiplier: 1.0 / speed
                        )
                        audioComp.scaleTimeRange(
                            CMTimeRange(start: audioAt, duration: audioInsertedRange.duration),
                            toDuration: audioPlay
                        )
                    }
                }
                next = CMTimeAdd(next, playDur)
            }
        } catch {
            return nil
        }
        guard CMTimeCompare(next, cursor) > 0 else { return nil }
        return next
    }

    /// 只插音频保留段到已有轨，供重叠接缝的双轨 AudioMix。
    /// - Parameters:
    ///   - audioComp: 工程音频轨
    ///   - asset: 本 clip 原片
    ///   - cursor: 插入点（工程播放轴）
    /// - Returns: 插入后的光标；无音轨则仍推进播放时长
    func appendAudio(
        audioComp: AVMutableCompositionTrack,
        from asset: AVAsset,
        at cursor: CMTime
    ) -> CMTime {
        let audioTrack = asset.tracks(withMediaType: .audio).first
        var next = cursor
        do {
            for segment in segments {
                let range = CMTimeRange(start: segment.sourceStart, end: segment.sourceEnd)
                guard range.duration.isValid, CMTimeGetSeconds(range.duration) >= 0.05 else { continue }
                let speed = AlbumTimelineEdit.clampedSpeed(segment.speed)
                let playDur = Self.playDuration(of: segment)
                if let audioTrack = audioTrack {
                    let audioRange = range.intersection(audioTrack.timeRange)
                    if audioRange.duration.isValid, CMTimeGetSeconds(audioRange.duration) >= 0.05 {
                        let audioAt = CMTimeAdd(next, CMTimeSubtract(audioRange.start, range.start))
                        try audioComp.insertTimeRange(audioRange, of: audioTrack, at: audioAt)
                        if !AlbumTimelineEdit.isUnitySpeed(speed) {
                            let audioPlay = CMTimeMultiplyByFloat64(
                                audioRange.duration,
                                multiplier: 1.0 / speed
                            )
                            audioComp.scaleTimeRange(
                                CMTimeRange(start: audioAt, duration: audioRange.duration),
                                toDuration: audioPlay
                            )
                        }
                    }
                }
                next = CMTimeAdd(next, playDur)
            }
        } catch {
            return CMTimeAdd(cursor, playDuration)
        }
        return next
    }

    /// 导出读取源：需要合成时用 Composition（播放轴从 0），否则原片。
    /// - Parameter asset: 相册原片
    /// - Returns: 给 Reader 的资源；合成失败则仍回原片
    func exportSource(from asset: AVAsset) -> AVAsset {
        if needsComposition, let composition = makeComposition(from: asset) {
            return composition
        }
        return asset
    }

    /// 导出读取区间：合成轴为 `[0, playDuration]`，单段 1x 为该段源区间。已读合成轴时调用方不得再乘 speed。
    /// - Returns: Reader.timeRange
    func exportTimeRange() -> CMTimeRange {
        if needsComposition {
            return CMTimeRange(start: .zero, duration: playDuration)
        }
        let segment = segments[0]
        return CMTimeRange(start: segment.sourceStart, end: segment.sourceEnd)
    }

    /// 一段在播放轴上的时长 = 源时长 / speed
    /// - Parameter segment: 保留段
    /// - Returns: 播放时长
    private static func playDuration(of segment: AlbumTimelineSegment) -> CMTime {
        let source = CMTimeSubtract(segment.sourceEnd, segment.sourceStart)
        return CMTimeMultiplyByFloat64(source, multiplier: 1.0 / AlbumTimelineEdit.clampedSpeed(segment.speed))
    }
}

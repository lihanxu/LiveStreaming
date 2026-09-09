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
    /// 已排序、不相交的保留段，speed 阶段 3 固定 1
    let segments: [AlbumTimelineSegment]

    /// 从文档解析保留段
    /// - Parameters:
    ///   - timeline: 剪辑文档时间线
    ///   - sourceDuration: 源时长
    init(timeline: AlbumTimelineEdit, sourceDuration: CMTime) {
        self.sourceDuration = sourceDuration
        self.segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
    }

    /// 播放轴总长 = 各段源时长之和（1x）
    var playDuration: CMTime {
        return segments.reduce(CMTime.zero) { partial, segment in
            CMTimeAdd(partial, CMTimeSubtract(segment.sourceEnd, segment.sourceStart))
        }
    }

    /// 两段及以上才需要 Composition；单段继续用原片 + 收尾
    var needsComposition: Bool {
        return segments.count >= 2
    }

    /// 把源 PTS 映射到播放轴；须属于该段。
    /// - Parameters:
    ///   - sourceTime: 该段内的源时间
    ///   - segment: 当前段
    ///   - playOffset: 该段在播放轴上的起点
    /// - Returns: 从 0 起算的播放时间
    func playTime(sourceTime: CMTime, in segment: AlbumTimelineSegment, playOffset: CMTime) -> CMTime {
        let local = CMTimeSubtract(sourceTime, segment.sourceStart)
        return CMTimeAdd(playOffset, CMTimeMaximum(local, .zero))
    }

    /// 按保留段顺序插入源轨，播放轴无缺口。
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
                try videoComp.insertTimeRange(range, of: videoTrack, at: cursor)
                if let audioTrack = audioTrack, let audioComp = audioComp {
                    let audioRange = range.intersection(audioTrack.timeRange)
                    if audioRange.duration.isValid, CMTimeGetSeconds(audioRange.duration) >= 0.05 {
                        let audioAt = CMTimeAdd(cursor, CMTimeSubtract(audioRange.start, range.start))
                        try audioComp.insertTimeRange(audioRange, of: audioTrack, at: audioAt)
                    }
                }
                cursor = CMTimeAdd(cursor, range.duration)
            }
        } catch {
            return nil
        }
        videoComp.preferredTransform = videoTrack.preferredTransform
        guard cursor.isValid, CMTimeCompare(cursor, .zero) > 0 else { return nil }
        return composition
    }

    /// 导出读取源：多段用 Composition（播放轴从 0 无缺口），单段用原片。
    /// - Parameter asset: 相册原片
    /// - Returns: 给 Reader 的资源；多段失败则仍回原片
    func exportSource(from asset: AVAsset) -> AVAsset {
        if needsComposition, let composition = makeComposition(from: asset) {
            return composition
        }
        return asset
    }

    /// 导出读取区间：多段为整条播放轴，单段为该段源区间。
    /// - Returns: Reader.timeRange
    func exportTimeRange() -> CMTimeRange {
        if needsComposition {
            return CMTimeRange(start: .zero, duration: playDuration)
        }
        let segment = segments[0]
        return CMTimeRange(start: segment.sourceStart, end: segment.sourceEnd)
    }
}

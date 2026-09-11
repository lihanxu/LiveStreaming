//
//  AlbumProjectMapper.swift
//  LiveStreaming
//
//  工程播放轴：各 clip 播放时长相接，非硬切接缝重叠 duration。
//

import AVFoundation
import CoreMedia

/// 工程轴上某一时刻落在哪一段 clip 上。
struct AlbumProjectContribution {
    /// `clips` 下标
    let clipIndex: Int
    /// 该 clip 自己的播放轴时间（从 0）
    let clipPlayTime: CMTime
    /// 该 clip 的源轴映射
    let mapper: AlbumTimeMapper
}

/// 某一工程时刻要解几路、怎么混。
struct AlbumProjectFramePlan {
    /// 当前段（转场时为 outgoing）
    let outgoing: AlbumProjectContribution
    /// 重叠时的下一段；硬切为 nil
    let incoming: AlbumProjectContribution?
    /// 接缝类型；无重叠时为 cut
    let kind: AlbumTransitionKind
    /// 0 全是 outgoing，1 全是 incoming
    let progress: Float
}

/// 多 `AVAsset` 工程时钟；不处理像素。
struct AlbumProjectMapper {
    /// 与 `AlbumProject.clips` 对齐的片源
    let assets: [AVAsset]
    /// 各片文档（画幅不参与时钟）
    let documents: [AlbumEditDocument]
    /// 接缝；数量不足时按硬切
    let transitions: [AlbumTransition]

    /// - Parameters:
    ///   - assets: 已加载的 AVAsset，数量须与 documents 一致
    ///   - documents: 各片时间线
    ///   - transitions: 接缝草稿
    init(assets: [AVAsset], documents: [AlbumEditDocument], transitions: [AlbumTransition] = []) {
        self.assets = assets
        self.documents = documents
        self.transitions = transitions
    }

    /// 每片一个 TimeMapper；数量不够时当空工程
    private var clipMappers: [AlbumTimeMapper] {
        guard assets.count == documents.count else { return [] }
        return zip(assets, documents).map { asset, document in
            AlbumTimeMapper(timeline: document.timeline, sourceDuration: asset.duration)
        }
    }

    /// 工程播放总长 = Σ clip.playDuration − Σ overlap
    var playDuration: CMTime {
        let mappers = clipMappers
        guard let lastStart = clipStarts(mappers: mappers).last,
              let lastMapper = mappers.last else {
            return .zero
        }
        return CMTimeAdd(lastStart, lastMapper.playDuration)
    }

    /// 两段及以上必须合成；单段仍交给该片 TimeMapper 决定
    var needsComposition: Bool {
        return assets.count >= 2
    }

    /// 是否有可见重叠（预览双解码 / 导出拉两路）
    var hasOverlap: Bool {
        let mappers = clipMappers
        guard mappers.count >= 2 else { return false }
        for index in 0..<(mappers.count - 1) {
            if CMTimeCompare(overlapDuration(atJunction: index, mappers: mappers), .zero) > 0 {
                return true
            }
        }
        return false
    }

    /// 接缝重叠；硬切或两侧太短则为 0。夹紧到 min(0.8s, 两侧播放时长 40%)。
    /// - Parameter index: clip[i] 与 clip[i+1]
    /// - Returns: 工程轴上交叠时长
    func overlapDuration(atJunction index: Int) -> CMTime {
        return overlapDuration(atJunction: index, mappers: clipMappers)
    }

    /// 工程播放时间落在哪一段（重叠时取 outgoing）
    /// - Parameter playTime: 从 0 起的工程轴
    /// - Returns: 贡献；时间非法或无片为 nil
    func contribution(at playTime: CMTime) -> AlbumProjectContribution? {
        return framePlan(at: playTime)?.outgoing
    }

    /// 该时刻的解码计划
    /// - Parameter playTime: 工程轴
    /// - Returns: 1 或 2 路
    func framePlan(at playTime: CMTime) -> AlbumProjectFramePlan? {
        let mappers = clipMappers
        guard !mappers.isEmpty, playTime.isValid else { return nil }
        let starts = clipStarts(mappers: mappers)
        let t = CMTimeMaximum(playTime, .zero)
        var hit: [Int] = []
        for index in mappers.indices {
            let start = starts[index]
            let end = CMTimeAdd(start, mappers[index].playDuration)
            let isLast = index == mappers.count - 1
            if CMTimeCompare(t, start) >= 0 {
                if CMTimeCompare(t, end) < 0 || (isLast && CMTimeCompare(t, end) <= 0) {
                    hit.append(index)
                }
            }
        }
        if hit.isEmpty {
            let last = mappers.count - 1
            return AlbumProjectFramePlan(
                outgoing: AlbumProjectContribution(
                    clipIndex: last,
                    clipPlayTime: mappers[last].playDuration,
                    mapper: mappers[last]
                ),
                incoming: nil,
                kind: .cut,
                progress: 0
            )
        }
        let outIndex = hit[0]
        let outgoing = AlbumProjectContribution(
            clipIndex: outIndex,
            clipPlayTime: CMTimeMaximum(CMTimeSubtract(t, starts[outIndex]), .zero),
            mapper: mappers[outIndex]
        )
        guard hit.count >= 2 else {
            return AlbumProjectFramePlan(outgoing: outgoing, incoming: nil, kind: .cut, progress: 0)
        }
        let inIndex = hit[1]
        let overlap = overlapDuration(atJunction: outIndex, mappers: mappers)
        let local = CMTimeMaximum(CMTimeSubtract(t, starts[inIndex]), .zero)
        let denom = max(CMTimeGetSeconds(overlap), 0.001)
        let progress = Float(min(1, max(0, CMTimeGetSeconds(local) / denom)))
        let kind: AlbumTransitionKind
        if transitions.indices.contains(outIndex) {
            kind = transitions[outIndex].kind
        } else {
            kind = .fade
        }
        return AlbumProjectFramePlan(
            outgoing: outgoing,
            incoming: AlbumProjectContribution(
                clipIndex: inIndex,
                clipPlayTime: local,
                mapper: mappers[inIndex]
            ),
            kind: kind,
            progress: progress
        )
    }

    /// 硬切拼一条无缺口播放轴；有重叠或单段返回 nil。
    /// - Returns: 多段合成；失败 nil
    func makeComposition() -> AVMutableComposition? {
        guard needsComposition, !hasOverlap else { return nil }
        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        if let firstVideo = assets.first?.tracks(withMediaType: .video).first {
            videoComp.preferredTransform = firstVideo.preferredTransform
        }
        var audioComp: AVMutableCompositionTrack?
        let hasAudio = assets.contains { !$0.tracks(withMediaType: .audio).isEmpty }
        if hasAudio {
            audioComp = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        var cursor = CMTime.zero
        for (asset, mapper) in zip(assets, clipMappers) {
            guard let next = mapper.append(
                videoComp: videoComp,
                audioComp: audioComp,
                from: asset,
                at: cursor
            ) else {
                return nil
            }
            cursor = next
        }
        guard cursor.isValid, CMTimeCompare(cursor, .zero) > 0 else { return nil }
        return composition
    }

    /// 重叠接缝用双音频轨 + 音量斜坡；无音频或无重叠为 nil。
    /// - Returns: 合成与 mix；失败 nil
    func makeOverlappingAudioMix() -> (AVMutableComposition, AVAudioMix)? {
        guard hasOverlap else { return nil }
        let mappers = clipMappers
        guard mappers.count == assets.count else { return nil }
        let hasAudio = assets.contains { !$0.tracks(withMediaType: .audio).isEmpty }
        guard hasAudio else { return nil }
        let composition = AVMutableComposition()
        guard let evenTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
              let oddTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return nil
        }
        let starts = clipStarts(mappers: mappers)
        for (index, asset) in assets.enumerated() {
            let track = index % 2 == 0 ? evenTrack : oddTrack
            _ = mappers[index].appendAudio(audioComp: track, from: asset, at: starts[index])
        }
        let evenParams = AVMutableAudioMixInputParameters(track: evenTrack)
        let oddParams = AVMutableAudioMixInputParameters(track: oddTrack)
        evenParams.setVolume(1, at: .zero)
        oddParams.setVolume(0, at: .zero)
        for junction in 0..<(mappers.count - 1) {
            let overlap = overlapDuration(atJunction: junction, mappers: mappers)
            guard CMTimeCompare(overlap, .zero) > 0 else { continue }
            let start = starts[junction + 1]
            let range = CMTimeRange(start: start, duration: overlap)
            let outgoing = junction % 2 == 0 ? evenParams : oddParams
            let incoming = junction % 2 == 0 ? oddParams : evenParams
            outgoing.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
            incoming.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [evenParams, oddParams]
        return (composition, mix)
    }

    /// 各 clip 在工程轴上的起点
    /// - Parameter mappers: clip TimeMapper
    /// - Returns: 与 clips 对齐
    private func clipStarts(mappers: [AlbumTimeMapper]) -> [CMTime] {
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for index in mappers.indices {
            starts.append(cursor)
            cursor = CMTimeAdd(cursor, mappers[index].playDuration)
            if index < mappers.count - 1 {
                cursor = CMTimeSubtract(cursor, overlapDuration(atJunction: index, mappers: mappers))
                if CMTimeCompare(cursor, .zero) < 0 {
                    cursor = .zero
                }
            }
        }
        return starts
    }

    /// 按两侧播放时长夹紧重叠
    /// - Parameters:
    ///   - index: 接缝下标
    ///   - mappers: clip 映射
    /// - Returns: 重叠；不可见则为 0
    private func overlapDuration(atJunction index: Int, mappers: [AlbumTimeMapper]) -> CMTime {
        guard mappers.indices.contains(index), mappers.indices.contains(index + 1) else {
            return .zero
        }
        let transition: AlbumTransition
        if transitions.indices.contains(index) {
            transition = transitions[index].normalized()
        } else {
            transition = .cut
        }
        if transition.kind == .cut {
            return .zero
        }
        let left = CMTimeGetSeconds(mappers[index].playDuration)
        let right = CMTimeGetSeconds(mappers[index + 1].playDuration)
        let budget = min(CMTimeGetSeconds(AlbumTransition.maximumOverlap), min(left, right) * 0.4)
        if budget < CMTimeGetSeconds(AlbumTransition.minimumOverlap) - 0.001 {
            return .zero
        }
        let wanted = CMTimeGetSeconds(transition.duration)
        let seconds = min(max(wanted, CMTimeGetSeconds(AlbumTransition.minimumOverlap)), budget)
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

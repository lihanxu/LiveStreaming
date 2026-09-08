//
//  AlbumTrimThumbnailLoader.swift
//  LiveStreaming
//
//  剪辑条缩略图：从源 AVAsset 按源时间均匀抽帧。不走滤镜 / Player。
//

import AVFoundation
import UIKit

/// 后台抽一组小图；新请求会取消上一轮，避免关面板后回填。
final class AlbumTrimThumbnailLoader {
    /// 当前 ImageGenerator；cancel 时置空
    private var generator: AVAssetImageGenerator?
    /// 递增以丢弃过期回调
    private var generation: UInt = 0

    /// 取消未完成的抽帧
    func cancel() {
        generation += 1
        generator?.cancelAllCGImageGeneration()
        generator = nil
    }

    /// 按条带格数在源时长上均匀取中点帧，逐张回主线程。
    /// - Parameters:
    ///   - asset: 相册视频
    ///   - count: 格子数，至少 1
    ///   - duration: 源时长
    ///   - maxPixel: 单边像素上限（已含 scale）
    ///   - onImage: 主线程；index 对应 0..<count
    func load(
        asset: AVAsset,
        count: Int,
        duration: CMTime,
        maxPixel: CGFloat,
        onImage: @escaping (Int, UIImage) -> Void
    ) {
        cancel()
        let cellCount = max(1, count)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let timescale = duration.timescale > 0 ? duration.timescale : 600
        // 1. 每格取窗口中点，避免第一格永远是黑场片头
        var times: [CMTime] = []
        times.reserveCapacity(cellCount)
        for index in 0..<cellCount {
            let seconds = (Double(index) + 0.5) / Double(cellCount) * durationSeconds
            times.append(CMTime(seconds: seconds, preferredTimescale: timescale))
        }
        let token = generation
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // 2. 放宽容差，优先附近关键帧，条带只认位置
        let slack = CMTime(seconds: 0.4, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = slack
        imageGenerator.requestedTimeToleranceAfter = slack
        generator = imageGenerator
        let values = times.map { NSValue(time: $0) }
        imageGenerator.generateCGImagesAsynchronously(forTimes: values) { requested, cgImage, _, result, _ in
            guard result == .succeeded, let cgImage = cgImage else { return }
            // requested 的 timescale 可能被 Generator 改过，取最近的一格
            var index = 0
            var best = CMTimeAbsoluteValue(CMTimeSubtract(times[0], requested))
            for cursor in 1..<times.count {
                let delta = CMTimeAbsoluteValue(CMTimeSubtract(times[cursor], requested))
                if CMTimeCompare(delta, best) < 0 {
                    best = delta
                    index = cursor
                }
            }
            let image = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                onImage(index, image)
            }
        }
    }
}

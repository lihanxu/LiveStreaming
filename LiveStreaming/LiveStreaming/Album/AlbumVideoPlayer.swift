//
//  AlbumVideoPlayer.swift
//  LiveStreaming
//
//  相册视频预览：AVPlayer + VideoOutput 出 BGRA 帧，供几何与滤镜实时处理。
//

import AVFoundation
import UIKit

/// 视频帧输出回调
protocol AlbumVideoPlayerDelegate: AnyObject {
    /// 当前播放时刻的一帧
    /// - Parameters:
    ///   - player: 播放器
    ///   - pixelBuffer: 32BGRA
    ///   - time: 媒体时间
    func videoPlayer(_ player: AlbumVideoPlayer, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime)
}

/// 相册视频播放与逐帧出图；音频由 AVPlayer 直接播放。
/// 单段：原片 + 入出点循环。多段：Item 绑 `AVMutableComposition`，播放轴无缺口，禁止逐帧跳删除段。
class AlbumVideoPlayer: NSObject {
    /// 帧回调
    weak var delegate: AlbumVideoPlayerDelegate?
    /// 底层播放器
    private var player: AVPlayer?
    /// 从 Item 抠像素
    private var videoOutput: AVPlayerItemVideoOutput?
    /// 与屏幕刷新同步取帧
    private var displayLink: CADisplayLink?
    /// 播到片尾（整段）时循环
    private var endObserver: NSObjectProtocol?
    /// 当前视频轨朝向；VideoOutput 不出正放像素，几何内核再 bake
    private(set) var preferredTransform = CGAffineTransform.identity
    /// 收尾入点；循环回到这里而不是 0
    private var trimStart = CMTime.zero
    /// 收尾出点；非法则用资源时长
    private var trimEnd = CMTime.invalid
    /// 用户点了播放；撞出点时 rate 会变成 0，靠这个决定是否循环
    private var userWantsPlayback = false
    /// 整段变速面板打开时的试听倍率；正式预览仍走 Composition
    private var previewRate: Float = 1
    /// 防止出点循环与 DidPlayToEndTime 叠两次 seek
    private var isHandlingLoop = false
    /// 拖动手柄时尚未发出的目标时间；只保留最新一次
    private var pendingScrubTime: CMTime?
    /// 已有一次 seek 在飞，完成后再跟 pending
    private var isSeeking = false

    /// 绑定 AVAsset 并套上单段收尾区间
    /// - Parameters:
    ///   - asset: 相册视频
    ///   - trimStart: 入点，默认片头
    ///   - trimEnd: 出点；非法则用 `asset.duration`
    func configure(with asset: AVAsset, trimStart: CMTime = .zero, trimEnd: CMTime = .invalid) {
        teardown()
        preferredTransform = .identity
        self.trimStart = CMTimeMaximum(trimStart, .zero)
        if trimEnd.isValid && CMTimeCompare(trimEnd, .zero) > 0 {
            self.trimEnd = trimEnd
        } else {
            self.trimEnd = asset.duration
        }
        let item = AVPlayerItem(asset: asset)
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelFormatOpenGLESCompatibility as String: true,
        ]
        // VideoOutput 只出编码朝向的像素。必须按 naturalSize 要 buffer；
        // 若用 transform 后的竖屏尺寸，横图会被硬拉成竖图（旋转+拉伸）。
        if let track = asset.tracks(withMediaType: .video).first {
            preferredTransform = track.preferredTransform
            let (width, height) = AlbumMediaConverter.scaledSize(
                originalWidth: Int(track.naturalSize.width.rounded()),
                originalHeight: Int(track.naturalSize.height.rounded()),
                maxLongEdge: AlbumMediaConverter.previewMaxLongEdge
            )
            attributes[kCVPixelBufferWidthKey as String] = width
            attributes[kCVPixelBufferHeightKey as String] = height
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        item.forwardPlaybackEndTime = self.trimEnd
        player = AVPlayer(playerItem: item)
        player?.actionAtItemEnd = .pause
        previewRate = 1
        installEndObserver(item: item)
        seek(to: self.trimStart)
    }

    /// 播放中改入出点，不重建 Item。暂停时不写下出点，否则拖出点会顶在 end 上取不到帧。
    /// - Parameters:
    ///   - start: 新入点
    ///   - end: 新出点
    func updateTrim(start: CMTime, end: CMTime) {
        trimStart = CMTimeMaximum(start, .zero)
        trimEnd = end
        applyPlaybackEndTime()
    }

    /// 拖动入出点：合并连续 seek，只跟最新目标，避免出点远跳被取消后松手才出一帧。
    /// - Parameter time: 要看的源时间
    func scrub(to time: CMTime) {
        pendingScrubTime = time
        performPendingScrubIfNeeded()
    }

    /// 精确 seek；完成后把当前帧交给预览（暂停时 DisplayLink 已停）
    /// - Parameters:
    ///   - time: 目标源时间
    ///   - completion: 是否完成
    func seek(to time: CMTime, completion: ((Bool) -> Void)? = nil) {
        let clamped = clampToTrim(time)
        player?.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                self?.copyFrame(at: clamped)
            }
            completion?(finished)
        }
    }

    /// 当前播放头
    /// - Returns: Item 时间；无 Item 则为 0
    func currentTime() -> CMTime {
        return player?.currentItem?.currentTime() ?? .zero
    }

    /// 暂停时改画幅/滤镜：再抠一帧，不必短暂 play
    func refreshCurrentFrame() {
        if !copyCurrentFrameToDelegate() {
            seek(to: currentTime())
        }
    }

    /// 开始播放并启动 DisplayLink
    func play() {
        userWantsPlayback = true
        applyPlaybackEndTime()
        applyPreviewRate()
        startDisplayLink()
    }

    /// 整段变速试听：只改 AVPlayer.rate，不改文档。分段页应传 1。
    /// - Parameter rate: 倍率，夹紧到时间线允许区间
    func setPreviewRate(_ rate: Float) {
        let minRate = Float(AlbumTimelineEdit.minimumSpeed)
        let maxRate = Float(AlbumTimelineEdit.maximumSpeed)
        previewRate = min(max(rate, minRate), maxRate)
        if userWantsPlayback {
            applyPreviewRate()
        }
    }

    /// 暂停播放与取帧
    func pause() {
        userWantsPlayback = false
        applyPlaybackEndTime()
        player?.pause()
        stopDisplayLink()
    }

    /// 是否正在播放
    /// - Returns: AVPlayer rate > 0
    func isPlaying() -> Bool {
        return (player?.rate ?? 0) > 0
    }

    /// 切换播放/暂停
    func togglePlayback() {
        if isPlaying() {
            pause()
        } else {
            play()
        }
    }

    /// 释放播放器与观察
    func teardown() {
        stopDisplayLink()
        removeEndObserver()
        player?.pause()
        player = nil
        videoOutput = nil
        preferredTransform = .identity
        userWantsPlayback = false
        isHandlingLoop = false
        pendingScrubTime = nil
        isSeeking = false
        previewRate = 1
        trimStart = .zero
        trimEnd = .invalid
    }

    /// 按 previewRate 开播（整段试听可能不是 1x）
    private func applyPreviewRate() {
        player?.rate = previewRate
    }

    /// 播放才限制出点；暂停放开，让拖出点能 seek 到该帧
    private func applyPlaybackEndTime() {
        if userWantsPlayback, trimEnd.isValid {
            player?.currentItem?.forwardPlaybackEndTime = trimEnd
        } else {
            player?.currentItem?.forwardPlaybackEndTime = .invalid
        }
    }

    /// 若没有在飞的 seek，发出 pending 目标；完成后再跟下一笔
    private func performPendingScrubIfNeeded() {
        guard !isSeeking, let target = pendingScrubTime else { return }
        pendingScrubTime = nil
        guard let player = player else { return }
        isSeeking = true
        // 1. 不夹到出点内侧，否则和松开出点限制对不上
        let clamped = CMTimeMaximum(target, .zero)
        // 2. 放宽容差，拖动手势要的是跟上，不是逐帧精确
        let slack = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: clamped, toleranceBefore: slack, toleranceAfter: slack) { [weak self] finished in
            guard let self = self else { return }
            self.isSeeking = false
            if finished {
                self.copyFrame(at: clamped)
            }
            self.performPendingScrubIfNeeded()
        }
    }

    /// 安装片尾循环观察
    /// - Parameter item: 当前 Item
    private func installEndObserver(item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleReachedTrimEnd()
        }
    }

    /// 卸掉片尾观察
    private func removeEndObserver() {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// 出点或片尾：seek 回入点；用户仍想播则继续
    private func handleReachedTrimEnd() {
        guard !isHandlingLoop else { return }
        isHandlingLoop = true
        let shouldContinue = userWantsPlayback
        seek(to: trimStart) { [weak self] _ in
            guard let self = self else { return }
            self.isHandlingLoop = false
            if shouldContinue {
                self.applyPreviewRate()
                self.startDisplayLink()
            }
        }
    }

    /// 把时间夹进当前收尾区间
    /// - Parameter time: 原始时间
    /// - Returns: `[trimStart, trimEnd)`
    private func clampToTrim(_ time: CMTime) -> CMTime {
        var clamped = CMTimeMaximum(time, trimStart)
        if trimEnd.isValid && CMTimeCompare(clamped, trimEnd) >= 0 {
            let step = CMTime(value: 1, timescale: max(trimEnd.timescale, 600))
            clamped = CMTimeMaximum(trimStart, CMTimeSubtract(trimEnd, step))
        }
        return clamped
    }

    /// 从 VideoOutput 抠一帧送给编辑页；先试目标时间，没有再试当前头
    /// - Parameter time: 希望显示的源时间
    /// - Returns: 是否拿到 buffer
    @discardableResult
    private func copyFrame(at time: CMTime) -> Bool {
        guard let output = videoOutput else { return false }
        if let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            delegate?.videoPlayer(self, didOutput: pixelBuffer, at: time)
            return true
        }
        let now = player?.currentItem?.currentTime() ?? time
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) else {
            return false
        }
        delegate?.videoPlayer(self, didOutput: pixelBuffer, at: now)
        return true
    }

    /// 从 VideoOutput 抠当前帧送给编辑页
    /// - Returns: 是否拿到 buffer
    @discardableResult
    private func copyCurrentFrameToDelegate() -> Bool {
        return copyFrame(at: player?.currentItem?.currentTime() ?? .zero)
    }

    /// 启动 CADisplayLink 拉取当前帧
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 停止 CADisplayLink
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 每帧向 delegate 投递 pixelBuffer
    @objc private func handleDisplayLink() {
        guard let output = videoOutput, let item = player?.currentItem else { return }
        let time = item.currentTime()
        // 出点不一定发 DidPlayToEndTime，播放中撞上则循环回入点
        if userWantsPlayback, trimEnd.isValid, CMTimeCompare(time, trimEnd) >= 0 {
            handleReachedTrimEnd()
            return
        }
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return
        }
        delegate?.videoPlayer(self, didOutput: pixelBuffer, at: time)
    }
}

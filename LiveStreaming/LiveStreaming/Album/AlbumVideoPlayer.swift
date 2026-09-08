//
//  AlbumVideoPlayer.swift
//  LiveStreaming
//
//  相册视频预览：AVPlayer + VideoOutput 出 BGRA 帧，供处理图实时加滤镜。
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
class AlbumVideoPlayer: NSObject {
    /// 帧回调
    weak var delegate: AlbumVideoPlayerDelegate?
    /// 底层播放器
    private var player: AVPlayer?
    /// 从 Item 抠像素
    private var videoOutput: AVPlayerItemVideoOutput?
    /// 与屏幕刷新同步取帧
    private var displayLink: CADisplayLink?
    /// 循环播放通知
    private var endObserver: NSObjectProtocol?

    /// 绑定 AVAsset 并准备输出
    /// - Parameter asset: 相册视频
    func configure(with asset: AVAsset) {
        teardown()
        let item = AVPlayerItem(asset: asset)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelFormatOpenGLESCompatibility as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        player = AVPlayer(playerItem: item)
        player?.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
    }

    /// 开始播放并启动 DisplayLink
    func play() {
        player?.play()
        startDisplayLink()
    }

    /// 暂停播放与取帧
    func pause() {
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
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        videoOutput = nil
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
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return
        }
        delegate?.videoPlayer(self, didOutput: pixelBuffer, at: time)
    }
}

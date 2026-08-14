//
//  AudioManager.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//
//  耳返入口，转发给 AudioPlayer。
//

import Foundation
import AVFAudio

/// 音频回放管理。
class AudioManager: NSObject {
    /// 实际播放器
    private var audioPlayer: AudioPlayer?
    
    /// 创建 AudioPlayer
    override init() {
        super.init()
        audioPlayer = AudioPlayer()
    }
    
    /// 是否正在播放
    /// - Returns: 引擎运行中为 true
    func isPlaying() -> Bool {
        return audioPlayer?.isPlaying() ?? false
    }
    
    /// 开始耳返
    func startPlayAudio() {
        audioPlayer?.start()
    }
    
    /// 停止耳返
    func stopPlayAudio() {
        audioPlayer?.stop()
    }
    
    /// 把采集到的音频交给播放器
    /// - Parameters:
    ///   - sampleBuffer: PCM 采样
    ///   - device: 来源设备
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        audioPlayer?.inputAudio(sampleBuffer: sampleBuffer, from: device)
    }
}

//
//  AudioMagician.swift
//  AudioBox
//
//  Created by anker on 2022/2/15.
//
//  实验用：把 Bundle 里的 mp3 循环播放。当前直播链路未接入。
//

import UIKit
import AVFoundation
import CocoaLumberjack

/// 用 AVAudioEngine 播放本地 mp3 的实验类。
class AudioMagician: NSObject {
    /// 打开的音频文件
    private var audioFile: AVAudioFile?
    /// 播放引擎
    private var audioEngine: AVAudioEngine!
    /// 主播放节点
    private var audioPlayerNode: AVAudioPlayerNode!
    /// 延迟启动的第二个播放节点
    private var otherPlayerNode: AVAudioPlayerNode!
    /// 预留停止定时器
    private var stopTimer: Timer!
    
    /// Bundle 中 fascinated.mp3
    private let filePath: URL? = {
        let path = Bundle.main.url(forResource: "fascinated", withExtension: "mp3")
        return path
    }()
    
    /// 10 秒后启动第二个节点
    override init() {
        super.init()
        perform(#selector(playOther), with: nil, afterDelay: 10.0)
    }
    
    /// 读入整首 mp3，双节点循环接到 mixer
    func playSound() {
        do {
            audioFile = try AVAudioFile(forReading: filePath!)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile!.processingFormat, frameCapacity: AVAudioFrameCount(audioFile!.length)) else { return }
            audioFile?.framePosition = 0
            try audioFile?.read(into: buffer)
            audioFile?.framePosition = 0

            audioEngine = AVAudioEngine()
            let mainMixer = audioEngine.mainMixerNode
            let output = audioEngine.outputNode

            audioPlayerNode = AVAudioPlayerNode()
            audioEngine.attach(audioPlayerNode)
            
            otherPlayerNode = AVAudioPlayerNode()
            audioEngine.attach(otherPlayerNode)

            audioEngine.connect(audioPlayerNode, to: mainMixer, format: buffer.format)
            audioEngine.connect(otherPlayerNode, to: mainMixer, format: buffer.format)
            audioEngine.connect(mainMixer, to: output, format: mainMixer.outputFormat(forBus: 0))

            audioEngine.prepare()
            try audioEngine.start()
            audioPlayerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            otherPlayerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            audioPlayerNode.play()
        } catch {
            DDLogError("Audio Magician play sound failed: \(error)")
        }
    }
    
    /// 延迟回调：启动第二个循环节点
    @objc func playOther() {
        otherPlayerNode.play()
    }
}

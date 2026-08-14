//
//  AudioPlayer.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//
//  用采集原始 PCM 格式播放，采样率/声道交给 AVAudioEngine 混音转换。
//

import Foundation
import AVFoundation
import CocoaLumberjack

/// 基于 AVAudioEngine 的耳返播放器。
class AudioPlayer: NSObject {
    /// 播放图：PlayerNode → Mixer → Output
    private var audioEngine: AVAudioEngine?
    /// 调度 PCM 的播放节点
    private var audioPlayerNode: AVAudioPlayerNode?
    
    /// 按采集格式搭建播放图
    /// - Parameter audioFormat: 与 CMSampleBuffer 一致的 AVAudioFormat
    func initAudioEngine(_ audioFormat: AVAudioFormat) {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DDLogError("Audio engine start failed: \(error)")
        }
        audioEngine = engine
        audioPlayerNode = playerNode
    }
    
    /// CMSampleBuffer → AVAudioPCMBuffer，首次调用时初始化引擎
    /// - Parameter sampleBuffer: 采集到的音频
    /// - Returns: 可 schedule 的 PCM；格式解析失败为 nil
    func scheduleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let sDescr = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let avFmt = AVAudioFormat(cmAudioFormatDescription: sDescr)
        if audioEngine == nil {
            initAudioEngine(avFmt)
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFmt, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: pcmBuffer.mutableAudioBufferList)
        return pcmBuffer
    }
    
    /// 把一块采集音频送进播放节点
    /// - Parameters:
    ///   - sampleBuffer: PCM 采样
    ///   - device: 来源设备（当前未使用，预留）
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        guard let buffer = scheduleBuffer(sampleBuffer) else { return }
        audioPlayerNode?.scheduleBuffer(buffer, completionHandler: nil)
        if audioPlayerNode?.isPlaying == false {
            audioPlayerNode?.play()
        }
    }
    
    /// 引擎是否在跑
    /// - Returns: audioEngine.isRunning
    func isPlaying() -> Bool {
        return audioEngine?.isRunning ?? false
    }
    
    /// 启动已创建的引擎；尚未收到首包时 engine 仍为 nil
    func start() {
        guard let audioEngine = audioEngine else {
            return
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            DDLogError("Audio engine play failed: \(error)")
        }
    }
    
    /// 停止播放节点并 reset 引擎
    func stop() {
        audioPlayerNode?.stop()
        if let audioEngine = audioEngine {
            audioEngine.stop()
            audioEngine.reset()
        }
    }
}

//
//  AudioPlayer.swift
//  LiveStreaming
//
//  Created by Hansen on 2022/3/18.
//
//  耳返：采集 PCM 先转成 AVAudioEngine 能接的标准 Float32，再送 PlayerNode。
//  采集 Int16 / 采样率与硬件不一致时，直接 connect 会在 iPhone 上抛 -10868。
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
    /// 采集格式 → 播放格式；相同时为 nil
    private var converter: AVAudioConverter?
    /// PlayerNode 连接用的标准 Float32 格式
    private var playFormat: AVAudioFormat?
    
    /// 按采集格式搭建播放图；节点一律用硬件采样率的 Float32
    /// - Parameter audioFormat: 与 CMSampleBuffer 一致的 AVAudioFormat
    func initAudioEngine(_ audioFormat: AVAudioFormat) {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        let mixer = engine.mainMixerNode
        let output = engine.outputNode
        // 1. 硬件总线采样率；会话未就绪时为 0，退回采集或 48k
        let hwRate = output.inputFormat(forBus: 0).sampleRate
        let srcRate = audioFormat.sampleRate
        let sampleRate = hwRate > 1000 ? hwRate : (srcRate > 1000 ? srcRate : 48000)
        let channels = max(1, min(2, audioFormat.channelCount))
        guard let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            DDLogError("audio play format create failed rate:\(sampleRate) ch:\(channels)")
            return
        }
        // 2. mixer→output 不指定 format，由引擎对齐硬件，避免 setFormat -10868
        engine.connect(playerNode, to: mixer, format: playFormat)
        engine.connect(mixer, to: output, format: nil)
        if !formatsCompatible(audioFormat, playFormat) {
            converter = AVAudioConverter(from: audioFormat, to: playFormat)
            if converter == nil {
                DDLogError("audio converter create failed src:\(audioFormat) dst:\(playFormat)")
            }
        } else {
            converter = nil
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DDLogError("Audio engine start failed: \(error)")
            return
        }
        self.playFormat = playFormat
        audioEngine = engine
        audioPlayerNode = playerNode
        DDLogInfo("audio ear-return ready src:\(audioFormat.sampleRate)/\(audioFormat.channelCount) play:\(sampleRate)/\(channels)")
    }
    
    /// 采样率、声道、PCM 类型都一致才可跳过转换
    /// - Parameters:
    ///   - a: 采集格式
    ///   - b: 播放格式
    /// - Returns: 可直接 schedule 为 true
    private func formatsCompatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return abs(a.sampleRate - b.sampleRate) < 0.5
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }
    
    /// CMSampleBuffer → 可送进 PlayerNode 的 Float32 PCM
    /// - Parameter sampleBuffer: 采集到的音频
    /// - Returns: 播放缓冲；格式或转换失败为 nil
    func scheduleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let sDescr = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let avFmt = AVAudioFormat(cmAudioFormatDescription: sDescr)
        if audioEngine == nil {
            initAudioEngine(avFmt)
        }
        guard let playFormat = playFormat else {
            return nil
        }
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: avFmt, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        srcBuffer.frameLength = AVAudioFrameCount(numSamples)
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: srcBuffer.mutableAudioBufferList)
        guard let converter = converter else {
            return srcBuffer
        }
        let ratio = playFormat.sampleRate / max(avFmt.sampleRate, 1)
        let outFrames = AVAudioFrameCount((Double(numSamples) * ratio).rounded(.up) + 32)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: outFrames) else {
            return nil
        }
        var gotSource = false
        var convertError: NSError?
        let status = converter.convert(to: dstBuffer, error: &convertError) { _, outStatus in
            if gotSource {
                outStatus.pointee = .noDataNow
                return nil
            }
            gotSource = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if status == .error {
            DDLogError("audio convert failed: \(String(describing: convertError))")
            return nil
        }
        return dstBuffer
    }
    
    /// 把一块采集音频送进播放节点
    /// - Parameters:
    ///   - sampleBuffer: PCM 采样
    ///   - device: 来源设备（当前未使用，预留）
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        guard let buffer = scheduleBuffer(sampleBuffer) else {
            return
        }
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
        converter = nil
        playFormat = nil
        audioEngine = nil
        audioPlayerNode = nil
    }
}

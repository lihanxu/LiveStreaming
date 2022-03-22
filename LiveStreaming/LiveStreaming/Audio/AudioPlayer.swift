//
//  AudioPlayer.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//

import Foundation
import AVFoundation

class AudioPlayer: NSObject {
    private var audioEngine:AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioConverter: AVAudioConverter?
    private let outputFormat: AVAudioFormat = {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100.0, channels: 1, interleaved: false)
        return format!
    } ()
    
    func initAudioEngine(_ audioFormat: AVAudioFormat?) {
        //初始化音频引擎组件
        audioEngine = AVAudioEngine()
        //初始化播放节点
        audioPlayerNode = AVAudioPlayerNode()
        //初始化转换器
        audioConverter = AVAudioConverter(from: audioFormat!, to: outputFormat)
        
        // 添加播放节点至音频引擎中
        audioEngine?.attach(audioPlayerNode!)
        audioEngine?.connect(audioPlayerNode!, to: audioEngine!.outputNode, format: outputFormat)
        audioEngine?.prepare()
        do {
            try audioEngine?.start()
        } catch {
            
        }
    }
    
    // CMSampleBuffer 转 AVAudioPCMBuffer
    func scheduleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // 获取 sampleBuffer 格式描述
        guard let sDescr: CMFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil}
        // 获取 sampleBuffer 采样数
        let numSamples: CMItemCount = CMSampleBufferGetNumSamples(sampleBuffer)
        // 获取 sampleBuffer 的音频格式
        let avFmt: AVAudioFormat = AVAudioFormat(cmAudioFormatDescription: sDescr)
        // 如果引擎没有初始化，则初始化引擎
        if audioEngine == nil {
            initAudioEngine(avFmt)
        }
        // 创建 AVAudioPCMBuffer
        let pcmBuffer: AVAudioPCMBuffer? = AVAudioPCMBuffer(pcmFormat: avFmt, frameCapacity: AVAudioFrameCount(UInt(numSamples)))
        pcmBuffer?.frameLength = AVAudioFrameCount(numSamples)

        // 将 sampleBuffer 中的音频数据拷贝到 pcmBuffer 中
        if let mutableAudioBufferList = pcmBuffer?.mutableAudioBufferList {
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: mutableAudioBufferList)
        }
        return pcmBuffer
    }
    
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        guard let buffer = scheduleBuffer(sampleBuffer) else { return }
        let pcmBuffer: AVAudioPCMBuffer? = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(1024*2))

        do {
            try audioConverter?.convert(to: pcmBuffer!, from: buffer)
        } catch {
            print("error audioConverter !!!!")
        }
        audioPlayerNode?.scheduleBuffer(pcmBuffer!, completionHandler: nil)
        audioPlayerNode?.play()
    }
    
    func isPlaying() -> Bool {
        return audioEngine?.isRunning ?? false
    }
    
    func start() {
        guard let audioEngine = audioEngine else {
            return
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Audio Magiciacn play sound failed!!!")
        }
    }
    
    func stop() {
        if let audioPlayerNode = audioPlayerNode {
            audioPlayerNode.stop()
        }
        if let audioEngine = audioEngine {
            audioEngine.stop()
            audioEngine.reset()
        }
    }
}

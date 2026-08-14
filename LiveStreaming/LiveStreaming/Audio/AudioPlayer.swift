//
//  AudioPlayer.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//

import Foundation
import AVFoundation
import CocoaLumberjack

class AudioPlayer: NSObject {
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    
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
        if let mutableAudioBufferList = pcmBuffer.mutableAudioBufferList {
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: mutableAudioBufferList)
        }
        return pcmBuffer
    }
    
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        guard let buffer = scheduleBuffer(sampleBuffer) else { return }
        audioPlayerNode?.scheduleBuffer(buffer, completionHandler: nil)
        if audioPlayerNode?.isPlaying == false {
            audioPlayerNode?.play()
        }
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
            DDLogError("Audio engine play failed: \(error)")
        }
    }
    
    func stop() {
        audioPlayerNode?.stop()
        if let audioEngine = audioEngine {
            audioEngine.stop()
            audioEngine.reset()
        }
    }
}

//
//  AudioManager.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//

import Foundation
import AVFAudio

class AudioManager: NSObject {
    private var audioPlayer: AudioPlayer?
    
    override init() {
        super.init()
        audioPlayer = AudioPlayer()
    }
    
    func isPlaying() -> Bool {
        return audioPlayer?.isPlaying() ?? false
    }
    
    func startPlayAudio() {
        audioPlayer?.start()
    }
    
    func stopPlayAudio() {
        audioPlayer?.stop()
    }
    
    func inputAudio(sampleBuffer: CMSampleBuffer, from device: OFInputDevice) {
        audioPlayer?.inputAudio(sampleBuffer: sampleBuffer, from: device)
    }
}

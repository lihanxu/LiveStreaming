//
//  AudioMagician.swift
//  AudioBox
//
//  Created by anker on 2022/2/15.
//

import UIKit
import AVFoundation

class AudioMagician: NSObject {
    private var audioFile: AVAudioFile?
    private var audioEngine:AVAudioEngine!
    private var audioPlayerNode: AVAudioPlayerNode!
    private var otherPlayerNode: AVAudioPlayerNode!
    private var stopTimer: Timer!
    
    private let filePath: URL? = {
        let path = Bundle.main.url(forResource: "fascinated", withExtension: "mp3")
        return path
    }()
    
    override init() {
        super.init()
        perform(#selector(playOther), with: nil, afterDelay: 10.0)
    }
    
    func playSound() {
        do {
            audioFile = try AVAudioFile(forReading: filePath!)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile!.processingFormat, frameCapacity: AVAudioFrameCount(audioFile!.length)) else { return }
            audioFile?.framePosition = 0
            try audioFile?.read(into: buffer)
            audioFile?.framePosition = 0

           
            // initialize audio engine components
            audioEngine = AVAudioEngine()
//            let input = audioEngine.inputNode
            let mainMixer = audioEngine.mainMixerNode
            let output = audioEngine.outputNode

            // node for playing audio
            audioPlayerNode = AVAudioPlayerNode()
            audioEngine.attach(audioPlayerNode)
            
            otherPlayerNode = AVAudioPlayerNode()
            audioEngine.attach(otherPlayerNode)

//            audioEngine.connect(input, to: mainMixer, format: input.outputFormat(forBus: 1))
            audioEngine.connect(audioPlayerNode, to: mainMixer, format: buffer.format)
            audioEngine.connect(otherPlayerNode, to: mainMixer, format: buffer.format)
            audioEngine.connect(mainMixer, to: output, format: mainMixer.outputFormat(forBus: 0))

            audioEngine.prepare()
            try audioEngine.start()
            audioPlayerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            otherPlayerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            audioPlayerNode.play()
        } catch {
            print("Audio Magiciacn play sound failed!!!")
        }
    }
    
    @objc func playOther() {
        otherPlayerNode.play()
    }
}

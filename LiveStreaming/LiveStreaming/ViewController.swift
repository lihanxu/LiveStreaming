//
//  ViewController.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/8.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var previewView: SCGLView!
    @IBOutlet weak var switchButton: UIButton!
    
    var inputDevice: OFInputDevice?
    lazy var singleColor: OFSingleColorMetalCompute = {
        let computer = OFSingleColorMetalCompute()
        return computer
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        inputDevice = OFInputDevice()
        inputDevice?.delegate = self
//        addPreviewLayer()
        //开启预览
        inputDevice?.startSession()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        previewView.start()
    }
    
    
    @IBAction func switchButtonDidClick(_ sender: Any) {
        print(#function)
        _ = inputDevice?.switchCameraPosition()
    }
}

extension ViewController: OFInputDeviceDelegate {
    func onRecvVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
//        DispatchQueue.main.async { [weak self] in
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
        
            let frame = VideoFrame()
            frame.frameWidth = CVPixelBufferGetWidth(pixelBuffer)
            frame.frameHeight = CVPixelBufferGetHeight(pixelBuffer)
            frame.pixelBuffer = pixelBuffer
//            self?.previewView.inputFrame(frame)
            singleColor.input(frame: frame) { [weak self] frameOut in
                self?.previewView.inputFrame(frameOut)
            }
//        }
    }
    
    func onRecvAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        
    }
}


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
            previewView.inputPixelBuffer(pixelBuffer)
//        }
    }
    
    func onRecvAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        
    }
}


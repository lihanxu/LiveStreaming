//
//  ViewController.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/8.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var previewView: UIView!
    @IBOutlet weak var switchButton: UIButton!
    
    var inputDevice: OFInputDevice?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        inputDevice = OFInputDevice()
        inputDevice?.startSession()
        addPreviewLayer()
    }
    
    /// 添加预览图层
    func addPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: inputDevice!.captureSession)
        previewView.layer.addSublayer(layer)
        layer.frame = previewView.bounds
    }
    
    @IBAction func switchButtonDidClick(_ sender: Any) {
        print(#function)
        _ = inputDevice?.switchCameraPosition()
    }
    
}


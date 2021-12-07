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
    // 功能按钮的父视图
    @IBOutlet weak var functionsView: UIView!
    // 输入源
    var inputDevice: OFInputDevice?
    // 功能按钮
    var buttonsView: OFButtonsView!
    
    let auxiliaryTools = OFAuxiliaryTools()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        initUI()
        initLayout()
        
        inputDevice = OFInputDevice()
        inputDevice?.delegate = self
        //开启预览
        inputDevice?.startSession()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        previewView.start()
    }
    
    private func initUI() {
        let items = auxiliaryTools.items.map { $0.rawValue }
        buttonsView = OFButtonsView(withItems: items)
        buttonsView.delegate = self
        functionsView.addSubview(buttonsView)
    }
    
    private func initLayout() {
        buttonsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonsView.topAnchor.constraint(equalTo: functionsView.topAnchor),
            buttonsView.bottomAnchor.constraint(equalTo: functionsView.bottomAnchor),
            buttonsView.leadingAnchor.constraint(equalTo: functionsView.leadingAnchor),
            buttonsView.trailingAnchor.constraint(equalTo: functionsView.trailingAnchor),
        ])
    }
}

extension ViewController: OFButtonsViewDelegate {
    func buttonDidSelect(_ view: OFButtonsView, index: Int) {
        if index >= auxiliaryTools.items.count {
            return
        }
        let type = auxiliaryTools.items[index]
        switch type {
        case .SwitchCamera:
            switchCamera()
        case .SingleColor:
            auxiliaryTools.switchSingleColor()
        case .EdgeDetection:
            auxiliaryTools.switchPeak()
        }
    }
    
    /// 切换前后摄像头
    func switchCamera() {
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
            auxiliaryTools.inputFrame(frame)
            previewView.inputFrame(frame)

//        }
    }
    
    func onRecvAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        
    }
}


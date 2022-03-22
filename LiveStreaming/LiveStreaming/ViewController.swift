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
    // 音频管理
    var audioMng: AudioManager?
    // 输入源
    var inputDevice: OFiPhoneInputDevice?
    // 功能按钮
    var buttonsView: OFButtonsView!
    
    let auxiliaryTools = OFAuxiliaryTools()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        initUI()
        initLayout()
        
        // 初始胡音频管理器
        audioMng = AudioManager()
        // 开始播放声音
        audioMng?.startPlayAudio()
        // 初始化设备
        inputDevice = OFiPhoneInputDevice()
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
        case .GaussianBlur:
            auxiliaryTools.switchGaussianBlur()
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
    func device(_ device: OFInputDevice, onReceiveVideo sampleBuffer: CMSampleBuffer) {
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
    
    func device(_ device: OFInputDevice, onReceiveAudio sampleBuffer: CMSampleBuffer) {
        audioMng?.inputAudio(sampleBuffer: sampleBuffer, from: device)
    }
}


//
//  ViewController.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/8.
//
//  主界面协调器：采集 → 处理图 → OpenGL 预览 / H.264 编码，音频走耳返。
//

import UIKit
import AVFoundation
import CocoaLumberjack

/// 直播预览页：把采集、滤镜、预览、编码、耳返串起来。
class ViewController: UIViewController {

    /// OpenGL ES 预览视图
    @IBOutlet weak var previewView: SCGLView!
    /// 底部功能按钮的容器
    @IBOutlet weak var functionsView: UIView!
    /// 耳返管理
    var audioMng: AudioManager?
    /// H.264 编码器，首帧时按分辨率创建
    var videoEncoder: VideoEncoder?
    /// 本机摄像头 + 麦克风
    var inputDevice: OFiPhoneInputDevice?
    /// 横向功能按钮条
    var buttonsView: OFButtonsView!
    
    /// 滤镜门面，内部是处理图
    let auxiliaryTools = OFAuxiliaryTools()
    
    /// 组装 UI、启动耳返和采集
    override func viewDidLoad() {
        super.viewDidLoad()
        initUI()
        initLayout()
        
        audioMng = AudioManager()
        audioMng?.startPlayAudio()
        inputDevice = OFiPhoneInputDevice()
        inputDevice?.delegate = self
        inputDevice?.startSession()
    }
    
    /// 页面可见后再开 CADisplayLink，避免后台空转
    override func viewDidAppear(_ animated: Bool) {
        previewView.start()
    }
    
    /// 按滤镜门面的功能列表创建按钮
    private func initUI() {
        let items = auxiliaryTools.items.map { auxiliaryTools.displayTitle(for: $0) }
        buttonsView = OFButtonsView(withItems: items)
        buttonsView.delegate = self
        functionsView.addSubview(buttonsView)
    }
    
    /// 按钮条铺满 functionsView
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
    /// 底部按钮点击：切摄像头或开关对应滤镜
    /// - Parameters:
    ///   - view: 按钮条
    ///   - index: 功能下标，与 `auxiliaryTools.items` 对齐
    func buttonDidSelect(_ view: OFButtonsView, index: Int) {
        if index >= auxiliaryTools.items.count {
            return
        }
        let type = auxiliaryTools.items[index]
        switch type {
        case .SwitchCamera:
            switchCamera()
        case .LUT:
            let title = auxiliaryTools.switchLUT()
            buttonsView.updateItem(at: index, text: title)
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
        DDLogInfo("switchCamera")
        _ = inputDevice?.switchCameraPosition()
    }
}

extension ViewController: OFInputDeviceDelegate {
    /// 视频采集回调：封装 VideoFrame → 处理图 → 预览，同时送进编码器
    func device(_ device: OFInputDevice, onReceiveVideo sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
    
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let frame = VideoFrame()
        frame.frameWidth = width
        frame.frameHeight = height
        frame.pixelBuffer = pixelBuffer
        auxiliaryTools.inputFrame(frame)
        previewView.inputFrame(frame)
    
        if videoEncoder == nil {
            videoEncoder = VideoEncoder(width: frame.frameWidth, height: frame.frameHeight, bitRate: Float(width * height * 2 * 32), frameRate: 25)
        }
        videoEncoder?.input(sampleBuffer: sampleBuffer)
    }
    
    /// 音频采集回调：耳返播放
    func device(_ device: OFInputDevice, onReceiveAudio sampleBuffer: CMSampleBuffer) {
        audioMng?.inputAudio(sampleBuffer: sampleBuffer, from: device)
    }
}

//
//  ViewController.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/8.
//
//  主界面协调器：采集 → 处理图 → OpenGL 预览 / H.264 编码，音频走耳返。
//  右上角设置按钮弹出底部参数卡片。
//

import UIKit
import AVFoundation
import CocoaLumberjack

/// 直播预览页：把采集、滤镜、预览、编码、耳返串起来。
class ViewController: UIViewController {

    /// OpenGL ES 预览视图
    @IBOutlet weak var previewView: SCGLView!
    /// Storyboard 里旧的底部按钮容器，已隐藏
    @IBOutlet weak var functionsView: UIView!
    /// 耳返管理
    var audioMng: AudioManager?
    /// H.264 编码器，首帧时按分辨率创建
    var videoEncoder: VideoEncoder?
    /// 本机摄像头 + 麦克风
    var inputDevice: OFiPhoneInputDevice?
    
    /// 滤镜门面，内部是处理图
    let auxiliaryTools = OFAuxiliaryTools()
    /// 设置页数据源
    private lazy var settingsController: OFSettingsController = {
        return OFSettingsController(tools: auxiliaryTools)
    }()
    /// 右上角入口
    private let settingsButton = UIButton(type: .system)
    /// 底部设置卡片
    private var settingsSheet: OFSettingsSheetView!
    
    /// 组装 UI、启动耳返和采集
    override func viewDidLoad() {
        super.viewDidLoad()
        initUI()
        initLayout()
        
        audioMng = AudioManager()
        audioMng?.startPlayAudio()
        inputDevice = OFiPhoneInputDevice()
        inputDevice?.delegate = self
        settingsController.inputDevice = inputDevice
        inputDevice?.startSession()
    }
    
    /// 页面可见后再开 CADisplayLink，避免后台空转
    override func viewDidAppear(_ animated: Bool) {
        previewView.start()
    }
    
    /// 隐藏旧按钮条，加上设置按钮和底部卡片
    private func initUI() {
        functionsView.isHidden = true
        functionsView.isUserInteractionEnabled = false
        
        settingsButton.setTitle("设置", for: .normal)
        settingsButton.setTitleColor(.white, for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        settingsButton.backgroundColor = UIColor(white: 0, alpha: 0.35)
        settingsButton.layer.cornerRadius = 16
        settingsButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        settingsButton.addTarget(self, action: #selector(handleSettingsTap), for: .touchUpInside)
        view.addSubview(settingsButton)
        
        settingsSheet = OFSettingsSheetView(controller: settingsController)
        view.addSubview(settingsSheet)
    }
    
    /// 设置按钮贴右上安全区，卡片铺满全屏做蒙层
    private func initLayout() {
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsSheet.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            
            settingsSheet.topAnchor.constraint(equalTo: view.topAnchor),
            settingsSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            settingsSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
    
    /// 弹出设置卡片
    @objc private func handleSettingsTap() {
        view.bringSubviewToFront(settingsSheet)
        settingsSheet.present()
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

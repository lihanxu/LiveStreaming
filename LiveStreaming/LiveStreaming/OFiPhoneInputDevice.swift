//
//  OFiPhoneInputDevice.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//
//  iPhone 摄像头 + 麦克风采集。输出 32BGRA 视频和 PCM 音频。
//

import Foundation
import AVFoundation
import CocoaLumberjack

/// 本机摄像头 + 麦克风采集。
class OFiPhoneInputDevice: OFInputDevice {
    /// AVFoundation 捕获会话
    let captureSession = AVCaptureSession()
    /// 前置广角
    var frontDevice: AVCaptureDevice?
    /// 后置镜头（优先连续自动对焦）
    var backDevice: AVCaptureDevice?
    /// 当前接入会话的视频输入
    var currentVideoInput: AVCaptureDeviceInput?
    /// 视频数据输出，像素格式 32BGRA
    var videoOutput: AVCaptureVideoDataOutput?

    /// 枚举镜头并搭建会话
    override init() {
        super.init()
        initDevices()
        setupSession()
    }
    
    /// 枚举前后摄像头，后置打开连续自动对焦
    private func initDevices() {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
        for device in devices {
            if device.position == .front {
                frontDevice = device
            } else if device.position == .back {
                backDevice = device
                try? device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus   //自动对焦
                device.unlockForConfiguration()
            }
        }
    }
    
    /*
        1. 初始化捕获会话
        2. 获取对应的设备
        3. 获取对应设备的输入源
        4. 添加输入源到捕获会话
        5. 添加输出到捕获会话
     */
    private func setupSession() {
        // 如果使用蓝牙耳机，则需要设置为false
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        // 获取视频设备
        guard let videoDevice = AVCaptureDevice.default(for: .video) else { return }
        do {
            // 视频输入
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
                currentVideoInput = videoInput
            }
        } catch {
            DDLogError("video input failed: \(error)")
        }
        
        // 获取音频设备
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        do {
            // 音频输入
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
        } catch {
            DDLogError("audio input failed: \(error)")
        }
        
        // 添加视频输出
        let videoQueue = DispatchQueue.init(label: "video output queue in capture session")
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput!.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput!.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        captureSession.addOutput(videoOutput!)
        // 设置输出视频方向
        let videoConnection = videoOutput?.connection(with: .video)
        videoConnection?.automaticallyAdjustsVideoMirroring = false
        videoConnection?.videoOrientation = .portrait
        
        // 添加音频输出
        let audioQueue = DispatchQueue.init(label: "audio output queue in capture session")
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        captureSession.addOutput(audioOutput)
        
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        }
    }
    
    /// 启动捕获；已在运行则忽略
    func startSession() {
        guard captureSession.isRunning == false else {
            return
        }
        captureSession.startRunning()
    }
    
    /// 停止捕获；未运行则忽略
    func stopSession() {
        guard captureSession.isRunning else {
            return
        }
        captureSession.stopRunning()
    }
    
    /// 切换摄像头位置
    /// - returns: 是否切换成功
    ///
    /// 切换摄像头位置，如果切换失败则返回false
    func switchCameraPosition() -> Bool {
        // 1. 前后镜头都要在
        guard let _ = frontDevice, let _ = backDevice else {
            return false
        }
        guard let videoInput = currentVideoInput, captureSession.inputs.contains(videoInput) else {
            return false
        }
        var device: AVCaptureDevice
        var position = videoInput.device.position
        switch position {
        case .front:
            device = backDevice!
            position = .back
        case .back:
            device = frontDevice!
            position = .front
        default:
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }
        // 2. 事务内替换视频输入，并按前置做镜像
        captureSession.beginConfiguration()
        captureSession.removeInput(videoInput)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentVideoInput = input
        } else {
            DDLogError("can not add new camera input")
        }
        //前置摄像头镜像
        let videoConnection = videoOutput?.connection(with: .video)
        videoConnection?.automaticallyAdjustsVideoMirroring = false
        videoConnection?.videoOrientation = .portrait
        if position == .front {
            videoConnection?.isVideoMirrored = true
        }
        captureSession.commitConfiguration()
       
        return true
    }
}

extension OFiPhoneInputDevice: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// 按输出类型把采样转给 delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            delegate?.device(self, onReceiveVideo: sampleBuffer)
        } else {
            delegate?.device(self, onReceiveAudio: sampleBuffer)
        }
    }

    /// 采集丢帧时打警告，便于排查负载
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        DDLogWarn("capture dropped a sample buffer")
    }
}

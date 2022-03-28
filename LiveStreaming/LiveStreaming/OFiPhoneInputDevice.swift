//
//  OFiPhoneInputDevice.swift
//  LiveStreaming
//
//  Created by anker on 2022/3/18.
//

import Foundation
import AVFoundation
import os.log

class OFiPhoneInputDevice: OFInputDevice {
    // 捕获会话
    let captureSession = AVCaptureSession()
    // 前置摄像头
    var frontDevice: AVCaptureDevice?
    // 后置摄像头
    var backDevice: AVCaptureDevice?
    var currentVideoInput: AVCaptureDeviceInput?
    var videoOutput: AVCaptureVideoDataOutput?

    override init() {
        super.init()
        initDevices()
        setupSession()
    }
    
    /// 初始化设备
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
            os_log("video input faield!", type:.error)
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
            os_log("audio input faield!", type:.error)
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
    
    func startSession() {
        guard captureSession.isRunning == false else {
            return
        }
        captureSession.startRunning()
    }
    
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
        captureSession.beginConfiguration()
        captureSession.removeInput(videoInput)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentVideoInput = input
        } else {
            os_log("can not add new input!!!", type: .error)
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
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            delegate?.device(self, onReceiveVideo: sampleBuffer)
        } else {
            delegate?.device(self, onReceiveAudio: sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print(#function)
    }
}

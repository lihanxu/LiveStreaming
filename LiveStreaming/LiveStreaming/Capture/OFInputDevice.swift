//
//  OFInputDevice.swift
//  LiveStreaming
//
//  Created by oldFace on 2021/11/8.
//
//  采集设备抽象。具体实现（本机摄像头）见 OFiPhoneInputDevice。
//

import Foundation

/// 音视频采样回调。
protocol OFInputDeviceDelegate: NSObjectProtocol {
    /// 收到一帧视频
    /// - Parameters:
    ///   - device: 来源设备
    ///   - sampleBuffer: 含 CVPixelBuffer 的采样
    func device(_ device: OFInputDevice, onReceiveVideo sampleBuffer: CMSampleBuffer)
    /// 收到一块音频 PCM
    /// - Parameters:
    ///   - device: 来源设备
    ///   - sampleBuffer: 音频采样
    func device(_ device: OFInputDevice, onReceiveAudio sampleBuffer: CMSampleBuffer)
}

/// 输入源基类，便于以后扩展外接相机等。
class OFInputDevice: NSObject {
    /// 采样回调，弱引用避免循环
    weak var delegate: OFInputDeviceDelegate?
    /// 设备序号（预留）
    var number: Int = 0
    /// 设备显示名（预留）
    var name: String?
    /// 额外描述（预留）
    var info: String?
}

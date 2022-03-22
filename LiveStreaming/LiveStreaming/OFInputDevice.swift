//
//  OFInputDevice.swift
//  LiveStreaming
//
//  Created by oldFace on 2021/11/8.
//

import Foundation

protocol OFInputDeviceDelegate: NSObjectProtocol {
    func device(_ device: OFInputDevice, onReceiveVideo sampleBuffer: CMSampleBuffer)
    func device(_ device: OFInputDevice, onReceiveAudio sampleBuffer: CMSampleBuffer)
}

class OFInputDevice: NSObject {
    weak var delegate: OFInputDeviceDelegate?
    var number: Int = 0
    var name: String?
    var info: String?
}

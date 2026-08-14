//
//  OFProcessNode.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

enum OFProcessNodeID: String, Hashable {
    case source
    case lut
    case singleColor
    case gaussianBlur
    case peak
    case sink
}

protocol OFProcessNode: AnyObject {
    var isEnabled: Bool { get }
    func process(_ frame: VideoFrame)
}

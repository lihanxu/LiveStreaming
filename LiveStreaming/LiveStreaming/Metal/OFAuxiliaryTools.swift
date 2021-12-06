//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFAuxiliaryTools: NSObject {
    let items = OFMetalFuntions.Funstions.allCases

    private lazy var singleColor: OFSingleColorMetalCompute = {
        let computer = OFSingleColorMetalCompute()
        return computer
    }()
    
    func inputFrame(_ frame: VideoFrame) {
        singleColor.input(frame: frame)
    }
    
    /// 切换 Single Color 类型
    func switchSingleColor() {
        let type = singleColor.colorType.rawValue
        singleColor.colorType = OFSingleColorMetalCompute.SingleColorType(rawValue: type + 1) ?? .none
    }
}

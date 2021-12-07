//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFAuxiliaryTools: NSObject {
    let items = OFMetalFuntions.Funstions.allCases

    private lazy var singleColor: OFSingleColorMetalComputer = {
        let computer = OFSingleColorMetalComputer()
        return computer
    }()
    
    private lazy var peak: OFPeakComputer = {
        let computer = OFPeakComputer()
        return computer
    }()
    
    func inputFrame(_ frame: VideoFrame) {
        singleColor.input(frame: frame)
        peak.input(frame: frame)
    }
    
    /// 切换 Single Color 类型
    func switchSingleColor() {
        let type = singleColor.colorType.rawValue
        singleColor.colorType = OFSingleColorMetalComputer.SingleColorType(rawValue: type + 1) ?? .none
    }
    
    func switchPeak() {
        peak.state = !peak.state
    }
}

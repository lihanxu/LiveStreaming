//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation

class OFAuxiliaryTools: NSObject {
    let items = OFMetalFuntions.Funstions.allCases
    private let processGraph = OFProcessGraph()
    
    private lazy var lut: OFLUTComputer = {
        return OFLUTComputer()
    }()
    
    private lazy var singleColor: OFSingleColorMetalComputer = {
        return OFSingleColorMetalComputer()
    }()
    
    private lazy var peak: OFPeakComputer = {
        return OFPeakComputer()
    }()
    
    private lazy var gaussianBlur: OFGaussianBlurComputer = {
        return OFGaussianBlurComputer()
    }()
    
    override init() {
        super.init()
        setupProcessGraph()
    }
    
    private func setupProcessGraph() {
        processGraph.addNode(.source)
        processGraph.addNode(.lut, processor: lut)
        processGraph.addNode(.singleColor, processor: singleColor)
        processGraph.addNode(.gaussianBlur, processor: gaussianBlur)
        processGraph.addNode(.peak, processor: peak)
        processGraph.addNode(.sink)
        
        processGraph.addEdge(from: .source, to: .lut)
        processGraph.addEdge(from: .lut, to: .singleColor)
        processGraph.addEdge(from: .singleColor, to: .gaussianBlur)
        processGraph.addEdge(from: .gaussianBlur, to: .peak)
        processGraph.addEdge(from: .peak, to: .sink)
    }
    
    func inputFrame(_ frame: VideoFrame) {
        processGraph.process(frame)
    }
    
    func displayTitle(for type: OFMetalFuntions.Funstions) -> String {
        switch type {
        case .LUT:
            return lut.currentPreset.displayName
        default:
            return type.rawValue
        }
    }
    
    func switchLUT() -> String {
        return lut.switchToNext().displayName
    }
    
    func switchSingleColor() {
        let type = singleColor.colorType.rawValue
        singleColor.colorType = OFSingleColorMetalComputer.SingleColorType(rawValue: type + 1) ?? .none
    }
    
    func switchPeak() {
        peak.state = !peak.state
    }
    
    func switchGaussianBlur() {
        gaussianBlur.enabled = !gaussianBlur.enabled
    }
}

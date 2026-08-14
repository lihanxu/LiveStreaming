//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  滤镜入口：组装默认处理图，并把 UI 开关转给对应节点。
//  默认链路：Source → LUT → SingleColor → GaussianBlur → Peak → Sink
//

import Foundation

/// 辅助滤镜门面，ViewController 只跟这一层打交道。
class OFAuxiliaryTools: NSObject {
    /// 底部功能按钮列表，顺序与 UI 一致
    let items = OFMetalFuntions.Funstions.allCases
    /// 实际调度 DAG
    private let processGraph = OFProcessGraph()
    
    /// LUT 调色节点
    private lazy var lut: OFLUTComputer = {
        return OFLUTComputer()
    }()
    
    /// 单通道 / 灰度节点
    private lazy var singleColor: OFSingleColorMetalComputer = {
        return OFSingleColorMetalComputer()
    }()
    
    /// 边缘检测节点
    private lazy var peak: OFPeakComputer = {
        return OFPeakComputer()
    }()
    
    /// 高斯模糊节点
    private lazy var gaussianBlur: OFGaussianBlurComputer = {
        return OFGaussianBlurComputer()
    }()
    
    /// 初始化时搭好默认处理图
    override init() {
        super.init()
        setupProcessGraph()
    }
    
    /// 注册节点并连成一条有向链。后续加贴纸等只需加顶点加边。
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
    
    /// 采集回调入口：把一帧送进图里按拓扑序处理
    /// - Parameter frame: 当前视频帧
    func inputFrame(_ frame: VideoFrame) {
        processGraph.process(frame)
    }
    
    /// 按钮文案；LUT 显示当前预设名
    /// - Parameter type: 功能类型
    /// - Returns: 展示字符串
    func displayTitle(for type: OFMetalFuntions.Funstions) -> String {
        switch type {
        case .LUT:
            return lut.currentPreset.displayName
        default:
            return type.rawValue
        }
    }
    
    /// 切换到下一个 LUT 预设
    /// - Returns: 新的按钮文案
    func switchLUT() -> String {
        return lut.switchToNext().displayName
    }
    
    /// 在 none / R / G / B / 灰度之间循环
    func switchSingleColor() {
        let type = singleColor.colorType.rawValue
        singleColor.colorType = OFSingleColorMetalComputer.SingleColorType(rawValue: type + 1) ?? .none
    }
    
    /// 开关边缘检测
    func switchPeak() {
        peak.state = !peak.state
    }
    
    /// 开关高斯模糊
    func switchGaussianBlur() {
        gaussianBlur.enabled = !gaussianBlur.enabled
    }
}

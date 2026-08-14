//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  滤镜入口：组装默认处理图，并把 UI 开关转给对应节点。
//  默认链路：Source → FaceLandmarker → Beauty → ColorAdjust → LUT → SingleColor → GaussianBlur → Peak → Sink
//

import Foundation
import CoreGraphics

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
    
    /// Face Landmarker：关键点底座
    private lazy var faceLandmarker: OFFaceLandmarkerComputer = {
        return OFFaceLandmarkerComputer()
    }()
    
    /// 美颜：磨皮、美白、亮眼、白牙
    private lazy var beauty: OFBeautyComputer = {
        let node = OFBeautyComputer()
        node.landmarker = faceLandmarker
        return node
    }()
    
    /// 全局调色节点（曝光、对比、色温等）
    private lazy var colorAdjust: OFColorAdjustComputer = {
        return OFColorAdjustComputer()
    }()
    
    /// 美颜总开关（与档位一起写入 GPU）
    private var beautyEnabled = false
    /// 是否在预览上画人脸网格
    private var faceMeshOverlayEnabled = false
    
    /// 初始化时搭好默认处理图
    override init() {
        super.init()
        setupProcessGraph()
    }
    
    /// 注册节点并连成一条有向链。后续加贴纸等只需加顶点加边。
    private func setupProcessGraph() {
        processGraph.addNode(.source)
        processGraph.addNode(.faceLandmarker, processor: faceLandmarker)
        processGraph.addNode(.beauty, processor: beauty)
        processGraph.addNode(.colorAdjust, processor: colorAdjust)
        processGraph.addNode(.lut, processor: lut)
        processGraph.addNode(.singleColor, processor: singleColor)
        processGraph.addNode(.gaussianBlur, processor: gaussianBlur)
        processGraph.addNode(.peak, processor: peak)
        processGraph.addNode(.sink)
        
        processGraph.addEdge(from: .source, to: .faceLandmarker)
        processGraph.addEdge(from: .faceLandmarker, to: .beauty)
        processGraph.addEdge(from: .beauty, to: .colorAdjust)
        processGraph.addEdge(from: .colorAdjust, to: .lut)
        processGraph.addEdge(from: .lut, to: .singleColor)
        processGraph.addEdge(from: .singleColor, to: .gaussianBlur)
        processGraph.addEdge(from: .gaussianBlur, to: .peak)
        processGraph.addEdge(from: .peak, to: .sink)
    }
    
    /// 采集回调入口：把一帧送进图里按拓扑序处理
    /// - Parameter frame: 当前视频帧
    func inputFrame(_ frame: VideoFrame) {
        processGraph.process(frame)
        faceLandmarker.applyDebugOverlayIfNeeded(frame)
    }
    
    /// 设置页 LUT 当前值：关闭显示「关」，否则显示预设名
    var lutValueText: String {
        if lut.currentPreset.fileName == nil {
            return "关"
        }
        return lut.currentPreset.displayName
    }
    
    /// 当前 LUT 预设下标
    var currentLUTIndex: Int {
        return lut.currentPresetIndex
    }
    
    /// 设置页单色当前值
    var singleColorValueText: String {
        return singleColor.colorType.displayName
    }
    
    /// 高斯模糊是否打开
    var isGaussianBlurEnabled: Bool {
        return gaussianBlur.enabled
    }
    
    /// Peak 描边是否打开
    var isPeakEnabled: Bool {
        return peak.state
    }
    
    /// 选中指定 LUT 预设
    /// - Parameter index: `OFLUTPreset.all` 下标
    func applyLUT(at index: Int) {
        lut.applyPreset(at: index)
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
    
    /// 美颜总开关：打开后开始跑 Face Landmarker，并按当前档位做 GPU
    /// - Parameter enabled: 是否开启
    func setBeautyEnabled(_ enabled: Bool) {
        beautyEnabled = enabled
        updateFaceLandmarkerFlags()
    }
    
    /// 把设置页档位写进美颜节点
    /// - Parameter settings: 总开关 + 四项档位
    func applyBeautySettings(_ settings: OFBeautySettings) {
        beautyEnabled = settings.isEnabled
        beauty.applySettings(settings)
        updateFaceLandmarkerFlags()
    }
    
    /// 人脸网格预览开关；打开时也会跑推理
    /// - Parameter enabled: 是否画点
    func setFaceMeshOverlayEnabled(_ enabled: Bool) {
        faceMeshOverlayEnabled = enabled
        updateFaceLandmarkerFlags()
    }
    
    /// 人脸网格是否在画
    var isFaceMeshOverlayEnabled: Bool {
        return faceMeshOverlayEnabled
    }
    
    /// 美颜是否打开
    var isBeautyEnabled: Bool {
        return beautyEnabled
    }
    
    /// 最近一次检测到的归一化人脸点，供后续美颜变形使用
    /// - Returns: 每张脸一组点
    func latestFaceLandmarks() -> [[CGPoint]] {
        return faceLandmarker.copyLatestFaces()
    }
    
    /// 美颜或网格任一打开就推理
    private func updateFaceLandmarkerFlags() {
        faceLandmarker.overlayEnabled = faceMeshOverlayEnabled
        faceLandmarker.inferenceEnabled = beautyEnabled || faceMeshOverlayEnabled
    }
    
    /// 根页调色格子摘要
    var colorAdjustSummary: String {
        return colorAdjust.currentParams.summaryText
    }
    
    /// 调色二级页滑杆数据
    /// - Returns: 当前全部滑杆行
    func colorAdjustSliderRows() -> [OFColorSliderRow] {
        return colorAdjust.currentParams.sliderRows()
    }
    
    /// 设置页拖动某一项
    /// - Parameters:
    ///   - key: 滑杆 ID
    ///   - value: 新值
    func updateColorAdjust(key: OFColorAdjustKey, value: Float) {
        var params = colorAdjust.currentParams
        params.setValue(value, for: key)
        colorAdjust.updateParams(params)
    }
    
    /// 全部滑杆归零并跳过 GPU
    func resetColorAdjust() {
        colorAdjust.resetParams()
    }
    
    /// 用一份完整参数覆盖（取消编辑时还原）
    /// - Parameter params: 进入调色页前的快照
    func replaceColorAdjustParams(_ params: OFColorAdjustParams) {
        colorAdjust.updateParams(params)
    }
    
    /// 当前调色参数副本
    var colorAdjustParams: OFColorAdjustParams {
        return colorAdjust.currentParams
    }
    
    /// 按住对比按钮时旁路调色
    /// - Parameter bypassed: true 看原片
    func setColorAdjustBypassed(_ bypassed: Bool) {
        colorAdjust.setBypassed(bypassed)
    }
}

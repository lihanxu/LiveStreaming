//
//  OFAuxiliaryTools.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  滤镜入口：组装默认处理图，并把 UI 开关转给对应节点。
//  默认链路：Source → FaceLandmarker → Beauty → FaceReshape → ColorAdjust → LUT → SingleColor → GaussianBlur → Peak → Transition → Sink
//

import Foundation
import CoreGraphics

/// 辅助滤镜门面，直播/相册宿主只跟这一层打交道。
public class OFAuxiliaryTools: NSObject {
    /// 本实例 GPU 资源（Metal + 像素池）
    public let context = OFFilterContext()
    /// 实际调度 DAG
    private let processGraph = OFProcessGraph()
    
    /// LUT 调色节点
    private lazy var lut: OFLUTComputer = {
        return OFLUTComputer(context: context)
    }()
    
    /// 单通道 / 灰度节点
    private lazy var singleColor: OFSingleColorMetalComputer = {
        return OFSingleColorMetalComputer(context: context)
    }()
    
    /// 边缘检测节点
    private lazy var peak: OFPeakComputer = {
        return OFPeakComputer(context: context)
    }()
    
    /// 高斯模糊节点
    private lazy var gaussianBlur: OFGaussianBlurComputer = {
        return OFGaussianBlurComputer(context: context)
    }()
    
    /// Face Landmarker：关键点底座
    private lazy var faceLandmarker: OFFaceLandmarkerComputer = {
        return OFFaceLandmarkerComputer()
    }()
    
    /// 美颜：磨皮、美肤 LUT、亮眼、白牙
    private lazy var beauty: OFBeautyComputer = {
        let node = OFBeautyComputer(context: context)
        node.landmarker = faceLandmarker
        return node
    }()
    
    /// 面部重塑：瘦脸、大眼、瘦鼻、嘴巴、发际线、下颌
    private lazy var faceReshape: OFFaceReshapeComputer = {
        let node = OFFaceReshapeComputer(context: context)
        node.landmarker = faceLandmarker
        return node
    }()
    
    /// 全局调色节点（曝光、对比、色温等）
    private lazy var colorAdjust: OFColorAdjustComputer = {
        return OFColorAdjustComputer(context: context)
    }()
    
    /// 场景转场：冻结旧画面再按模版混入当前帧
    private lazy var transition: OFTransitionComputer = {
        return OFTransitionComputer(context: context)
    }()
    
    /// 美颜总开关（与档位一起写入 GPU）
    private var beautyEnabled = false
    /// 是否在预览上画人脸网格
    private var faceMeshOverlayEnabled = false
    
    /// 初始化时搭好默认处理图
    public override init() {
        super.init()
        setupProcessGraph()
    }
    
    /// 注册节点并连成一条有向链。后续加贴纸等只需加顶点加边。
    private func setupProcessGraph() {
        processGraph.addNode(.source)
        processGraph.addNode(.faceLandmarker, processor: faceLandmarker)
        processGraph.addNode(.beauty, processor: beauty)
        processGraph.addNode(.faceReshape, processor: faceReshape)
        processGraph.addNode(.colorAdjust, processor: colorAdjust)
        processGraph.addNode(.lut, processor: lut)
        processGraph.addNode(.singleColor, processor: singleColor)
        processGraph.addNode(.gaussianBlur, processor: gaussianBlur)
        processGraph.addNode(.peak, processor: peak)
        processGraph.addNode(.transition, processor: transition)
        processGraph.addNode(.sink)
        
        processGraph.addEdge(from: .source, to: .faceLandmarker)
        processGraph.addEdge(from: .faceLandmarker, to: .beauty)
        processGraph.addEdge(from: .beauty, to: .faceReshape)
        processGraph.addEdge(from: .faceReshape, to: .colorAdjust)
        processGraph.addEdge(from: .colorAdjust, to: .lut)
        processGraph.addEdge(from: .lut, to: .singleColor)
        processGraph.addEdge(from: .singleColor, to: .gaussianBlur)
        processGraph.addEdge(from: .gaussianBlur, to: .peak)
        processGraph.addEdge(from: .peak, to: .transition)
        processGraph.addEdge(from: .transition, to: .sink)
    }
    
    /// 滤镜输出像素池，相册拷贝帧时复用同一实例
    public var pixelBufferPool: OFPixelBufferTool {
        return context.pixelBufferPool
    }

    /// 采集回调入口：把一帧送进图里按拓扑序处理
    /// - Parameter frame: 当前视频帧
    public func inputFrame(_ frame: VideoFrame) {
        processGraph.process(frame)
        faceLandmarker.applyDebugOverlayIfNeeded(frame)
    }
    
    /// 设置页 LUT 当前值：关闭显示「关」，否则显示预设名
    public var lutValueText: String {
        if lut.currentPreset.fileName == nil {
            return "关"
        }
        return lut.currentPreset.displayName
    }
    
    /// 当前 LUT 预设下标
    public var currentLUTIndex: Int {
        return lut.currentPresetIndex
    }
    
    /// 设置页单色当前值
    public var singleColorValueText: String {
        return singleColor.colorType.displayName
    }
    
    /// 高斯模糊是否打开
    public var isGaussianBlurEnabled: Bool {
        return gaussianBlur.enabled
    }
    
    /// Peak 描边是否打开
    public var isPeakEnabled: Bool {
        return peak.state
    }
    
    /// 选中指定 LUT 预设
    /// - Parameter index: `OFLUTPreset.all` 下标
    public func applyLUT(at index: Int) {
        lut.applyPreset(at: index)
    }
    
    /// LUT 灵敏度 0…100
    public var lutIntensitySlider: Float {
        return lut.intensitySlider
    }
    
    /// 写入 LUT 灵敏度
    /// - Parameter value: 0…100
    public func setLUTIntensity(_ value: Float) {
        lut.setIntensitySlider(value)
    }
    
    /// 按住对比时旁路 LUT
    /// - Parameter bypassed: true 看未套 LUT 的画面
    public func setLUTBypassed(_ bypassed: Bool) {
        lut.setBypassed(bypassed)
    }

    /// 在 none / R / G / B / 灰度之间循环
    public func switchSingleColor() {
        let type = singleColor.colorType.rawValue
        singleColor.colorType = OFSingleColorMetalComputer.SingleColorType(rawValue: type + 1) ?? .none
    }
    
    /// 开关边缘检测
    public func switchPeak() {
        peak.state = !peak.state
    }
    
    /// 开关高斯模糊
    public func switchGaussianBlur() {
        gaussianBlur.enabled = !gaussianBlur.enabled
    }
    
    /// 美颜总开关：打开后开始跑 Face Landmarker，并按当前档位做 GPU
    /// - Parameter enabled: 是否开启
    public func setBeautyEnabled(_ enabled: Bool) {
        beautyEnabled = enabled
        updateFaceLandmarkerFlags()
    }
    
    /// 把设置页档位写进美颜和面部重塑节点
    /// - Parameter settings: 总开关 + 着色档位 + 形变档位
    public func applyBeautySettings(_ settings: OFBeautySettings) {
        beautyEnabled = settings.isEnabled
        beauty.applySettings(settings)
        faceReshape.applySettings(settings)
        updateFaceLandmarkerFlags()
    }
    
    /// 人脸网格预览开关；打开时也会跑推理
    /// - Parameter enabled: 是否画点
    public func setFaceMeshOverlayEnabled(_ enabled: Bool) {
        faceMeshOverlayEnabled = enabled
        updateFaceLandmarkerFlags()
    }
    
    /// 人脸网格是否在画
    public var isFaceMeshOverlayEnabled: Bool {
        return faceMeshOverlayEnabled
    }
    
    /// 美颜是否打开
    public var isBeautyEnabled: Bool {
        return beautyEnabled
    }
    
    /// 最近一次检测到的归一化人脸点，供后续美颜变形使用
    /// - Returns: 每张脸一组点
    public func latestFaceLandmarks() -> [[CGPoint]] {
        return faceLandmarker.copyLatestFaces()
    }
    
    /// 美颜或网格打开才推理
    private func updateFaceLandmarkerFlags() {
        faceLandmarker.overlayEnabled = faceMeshOverlayEnabled
        faceLandmarker.inferenceEnabled = beautyEnabled || faceMeshOverlayEnabled
    }
    
    /// 根页调色格子摘要
    public var colorAdjustSummary: String {
        return colorAdjust.currentParams.summaryText
    }
    
    /// 调色二级页滑杆数据
    /// - Returns: 当前全部滑杆行
    public func colorAdjustSliderRows() -> [OFColorSliderRow] {
        return colorAdjust.currentParams.sliderRows()
    }
    
    /// 设置页拖动某一项
    /// - Parameters:
    ///   - key: 滑杆 ID
    ///   - value: 新值
    public func updateColorAdjust(key: OFColorAdjustKey, value: Float) {
        var params = colorAdjust.currentParams
        params.setValue(value, for: key)
        colorAdjust.updateParams(params)
    }
    
    /// 全部滑杆归零并跳过 GPU
    public func resetColorAdjust() {
        colorAdjust.resetParams()
    }
    
    /// 用一份完整参数覆盖（取消编辑时还原）
    /// - Parameter params: 进入调色页前的快照
    public func replaceColorAdjustParams(_ params: OFColorAdjustParams) {
        colorAdjust.updateParams(params)
    }
    
    /// 当前调色参数副本
    public var colorAdjustParams: OFColorAdjustParams {
        return colorAdjust.currentParams
    }
    
    /// 按住对比按钮时旁路调色
    /// - Parameter bypassed: true 看原片
    public func setColorAdjustBypassed(_ bypassed: Bool) {
        colorAdjust.setBypassed(bypassed)
    }
    
    /// 按住对比按钮时旁路美颜着色
    /// - Parameter bypassed: true 看未磨皮美肤的画面
    public func setBeautyToneBypassed(_ bypassed: Bool) {
        beauty.setBypassed(bypassed)
    }
    
    /// 按住对比按钮时旁路面部重塑
    /// - Parameter bypassed: true 看未变形的脸
    public func setFaceReshapeBypassed(_ bypassed: Bool) {
        faceReshape.setBypassed(bypassed)
    }
    
    /// 设置页转场当前值
    public var transitionValueText: String {
        return transition.currentPreset.displayName
    }
    
    /// 当前转场预设下标
    public var currentTransitionIndex: Int {
        return transition.currentPresetIndex
    }
    
    /// 选中转场模版并预览一次
    /// - Parameter index: `OFTransitionPreset.all` 下标
    public func applyTransition(at index: Int) {
        transition.applyPreset(at: index)
    }
    
    /// 切摄像头前：已选模版则冻结下一帧再播
    public func playArmedTransition() {
        transition.playIfArmed()
    }
    
    /// 转场时长滑杆 0…100
    public var transitionDurationSlider: Float {
        return transition.durationSliderValue
    }
    
    /// 写入转场时长
    /// - Parameter value: 0…100
    public func setTransitionDuration(_ value: Float) {
        transition.setDurationSlider(value)
    }
    
    /// 时长滑杆回到默认
    public func resetTransitionDuration() {
        transition.resetDurationSlider()
    }
}

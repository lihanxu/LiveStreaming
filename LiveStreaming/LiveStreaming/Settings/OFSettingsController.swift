//
//  OFSettingsController.swift
//  LiveStreaming
//
//  设置页数据源：组装网格、把点击转到滤镜 / 摄像头 / 美颜。
//  新增参数时在 makeRootPage 加一项，并在 performTap 里处理即可。
//

import AVFoundation
import Foundation
import CocoaLumberjack

/// 设置页使用场景：直播含摄像头/转场，相册只保留静态媒体可用的滤镜。
enum OFSettingsContext {
    /// 实时流预览
    case live
    /// 相册编辑
    case album
}

/// 设置页业务逻辑，不负责动画。
class OFSettingsController {
    /// 滤镜门面
    private let tools: OFAuxiliaryTools
    /// 直播 / 相册；相册根页隐藏摄像头与转场
    let context: OFSettingsContext
    /// 用来读/切摄像头；未就绪时格子显示「--」
    weak var inputDevice: OFiPhoneInputDevice?
    /// 美颜占位状态
    let beauty = OFBeautySettings()
    /// 进入调色页时的参数快照；点 X 时还原
    private var colorAdjustBackup: OFColorAdjustParams?
    /// 参数变更后通知宿主重跑处理图（相册照片需从 source 重算）
    var onPipelineChanged: (() -> Void)?
    
    /// - Parameters:
    ///   - tools: 已搭好处理图的门面
    ///   - context: 使用场景，默认直播
    init(tools: OFAuxiliaryTools, context: OFSettingsContext = .live) {
        self.tools = tools
        self.context = context
    }
    
    /// 通知外部刷新预览（相册照片必须重跑 source）
    func notifyPipelineChanged() {
        onPipelineChanged?()
    }
    
    /// 按页 ID 生成当前快照
    /// - Parameter id: 根页或二级页
    /// - Returns: 标题 + 格子
    func page(for id: OFSettingsPageID) -> OFSettingsPage {
        switch id {
        case .root:
            return makeRootPage()
        case .lut:
            return makeLUTPage()
        case .cartoon:
            return makeCartoonPage()
        case .beauty:
            return makeBeautyPage()
        case .whiteningStyle:
            return makeWhiteningStylePage()
        case .faceReshape:
            return makeFaceReshapePage()
        case .colorAdjust:
            return makeColorAdjustPage()
        case .transition:
            return makeTransitionPage()
        }
    }
    
    /// 处理格子点击
    /// - Parameter id: 被点中的设置项
    /// - Returns: 刷新当前页或 push 二级页
    func performTap(_ id: OFSettingID) -> OFSettingsTapResult {
        switch id {
        case .camera:
            guard context == .live else { return .reload }
            tools.playArmedTransition()
            _ = inputDevice?.switchCameraPosition()
            DDLogInfo("settings camera -> \(cameraValueText())")
            notifyPipelineChanged()
            return .reload
        case .lut:
            return .push(.lut)
        case .lutPreset(let index):
            tools.applyLUT(at: index)
            notifyPipelineChanged()
            return .reload
        case .cartoon:
            return .push(.cartoon)
        case .cartoonPreset(let index):
            tools.applyCartoon(at: index)
            notifyPipelineChanged()
            return .reload
        case .singleColor:
            tools.switchSingleColor()
            notifyPipelineChanged()
            return .reload
        case .gaussianBlur:
            tools.switchGaussianBlur()
            notifyPipelineChanged()
            return .reload
        case .edgeDetection:
            tools.switchPeak()
            notifyPipelineChanged()
            return .reload
        case .beauty:
            return .push(.beauty)
        case .whiteningStylePreset(let style):
            beauty.leaveOneClickKeepingValues()
            beauty.whiteningStyle = style
            syncBeautyMaster()
            return .reload
        case .faceReshape:
            return .push(.faceReshape)
        case .colorAdjust:
            return .push(.colorAdjust)
        case .colorParam:
            return .reload
        case .transition:
            return .push(.transition)
        case .transitionPreset(let index):
            tools.applyTransition(at: index)
            notifyPipelineChanged()
            return .reload
        case .beautyMaster:
            beauty.isEnabled.toggle()
            tools.applyBeautySettings(beauty)
            DDLogInfo("beauty master \(beauty.isEnabled)")
            notifyPipelineChanged()
            return .reload
        case .faceMeshOverlay:
            tools.setFaceMeshOverlayEnabled(!tools.isFaceMeshOverlayEnabled)
            syncBeautyMaster()
            notifyPipelineChanged()
            return .reload
        }
    }
    
    /// 主卡片：已实现滤镜 + 美颜入口，后续参数往这里追加
    /// - Returns: 根页
    private func makeRootPage() -> OFSettingsPage {
        var items: [OFSettingItem] = []
        if context == .live {
            items.append(OFSettingItem(id: .camera, title: "摄像头", valueText: cameraValueText(), interaction: .cycle))
        }
        items.append(contentsOf: [
            OFSettingItem(id: .lut, title: "LUT", valueText: tools.lutValueText, interaction: .drillIn(.lut)),
            OFSettingItem(id: .cartoon, title: "漫画风", valueText: tools.cartoonValueText, interaction: .drillIn(.cartoon)),
            OFSettingItem(id: .singleColor, title: "单色", valueText: tools.singleColorValueText, interaction: .cycle),
            OFSettingItem(id: .gaussianBlur, title: "高斯模糊", valueText: tools.isGaussianBlurEnabled ? "开" : "关", interaction: .toggle),
            OFSettingItem(id: .edgeDetection, title: "描边", valueText: tools.isPeakEnabled ? "开" : "关", interaction: .toggle),
        ])
        if context == .live {
            items.append(OFSettingItem(id: .transition, title: "转场", valueText: tools.transitionValueText, interaction: .drillIn(.transition)))
        }
        items.append(contentsOf: [
            OFSettingItem(id: .beauty, title: "美颜", valueText: beauty.summaryText, interaction: .drillIn(.beauty)),
            OFSettingItem(id: .colorAdjust, title: "调色", valueText: tools.colorAdjustSummary, interaction: .drillIn(.colorAdjust)),
        ])
        return OFSettingsPage(id: .root, title: "设置", items: items)
    }
    
    /// LUT 二级页：横向预设 + 灵敏度滑杆，对齐调色
    /// - Returns: LUT 页
    private func makeLUTPage() -> OFSettingsPage {
        let current = tools.currentLUTIndex
        let options = OFLUTPreset.all.enumerated().map { index, preset in
            OFOptionSliderRow(id: index, title: preset.fileName == nil ? "关" : preset.displayName)
        }
        let enabled = OFLUTPreset.all.indices.contains(current) && OFLUTPreset.all[current].fileName != nil
        return OFSettingsPage(
            id: .lut,
            title: "LUT",
            optionSlider: OFOptionSliderPage(
                options: options,
                selectedID: current,
                intensity: tools.lutIntensitySlider,
                intensityEnabled: enabled
            )
        )
    }
    
    /// 漫画风二级页：关闭 / 宫崎骏 / 新海诚
    /// - Returns: 漫画风页
    private func makeCartoonPage() -> OFSettingsPage {
        let current = tools.currentCartoonIndex
        var items: [OFSettingItem] = []
        for (index, preset) in OFCartoonPreset.all.enumerated() {
            let mark = index == current ? "已选" : "—"
            items.append(OFSettingItem(id: .cartoonPreset(index), title: preset.displayName, valueText: mark, interaction: .cycle))
        }
        return OFSettingsPage(id: .cartoon, title: "漫画风", items: items)
    }
    
    /// 美颜二级页：横向图标 + 滑杆；点美肤进入滤镜二级页
    /// - Returns: 美颜页
    private func makeBeautyPage() -> OFSettingsPage {
        return OFSettingsPage(
            id: .beauty,
            title: "美颜",
            beautySliders: beauty.beautySliderRows(meshOn: tools.isFaceMeshOverlayEnabled)
        )
    }
    
    /// 美肤滤镜页：冷白 / 暖白 / 粉嫩 + 灵敏度，对齐 LUT 页
    /// - Returns: 美肤页
    private func makeWhiteningStylePage() -> OFSettingsPage {
        let options = OFWhiteningStyle.allCases.map { style in
            OFOptionSliderRow(id: style.rawValue, title: style.title)
        }
        return OFSettingsPage(
            id: .whiteningStyle,
            title: "美肤",
            optionSlider: OFOptionSliderPage(
                options: options,
                selectedID: beauty.whiteningStyle.rawValue,
                intensity: beauty.whitening,
                intensityEnabled: true
            )
        )
    }
    
    /// 面部重塑页：六项灵敏度滑杆
    /// - Returns: 重塑页
    private func makeFaceReshapePage() -> OFSettingsPage {
        return OFSettingsPage(id: .faceReshape, title: "面部重塑", reshapeSliders: beauty.reshapeSliderRows())
    }
    
    /// 调色二级页：列表滑杆，拖动即写入处理图
    /// - Returns: 滑杆页
    private func makeColorAdjustPage() -> OFSettingsPage {
        return OFSettingsPage(id: .colorAdjust, title: "调色", sliders: tools.colorAdjustSliderRows())
    }
    
    /// 转场二级页：横向模版 + 时长滑杆
    /// - Returns: 转场页
    private func makeTransitionPage() -> OFSettingsPage {
        let current = tools.currentTransitionIndex
        let options = OFTransitionPreset.all.enumerated().map { index, preset in
            OFOptionSliderRow(id: index, title: preset.displayName)
        }
        let enabled = OFTransitionPreset.all.indices.contains(current) && OFTransitionPreset.all[current].style != nil
        return OFSettingsPage(
            id: .transition,
            title: "转场",
            optionSlider: OFOptionSliderPage(
                options: options,
                selectedID: current,
                intensity: tools.transitionDurationSlider,
                intensityEnabled: enabled
            )
        )
    }
    
    /// 选中 LUT 预设；从关切到有色表时若灵敏度为 0 则拉满，避免看起来没效果
    /// - Parameter id: 预设下标
    func selectLUTOption(_ id: Int) {
        tools.applyLUT(at: id)
        let hasLUT = OFLUTPreset.all.indices.contains(id) && OFLUTPreset.all[id].fileName != nil
        if hasLUT, tools.lutIntensitySlider < 0.5 {
            tools.setLUTIntensity(100)
        }
        notifyPipelineChanged()
    }
    
    /// 拖动 LUT 灵敏度
    /// - Parameter value: 0…100
    func updateLUTIntensity(_ value: Float) {
        tools.setLUTIntensity(value)
        notifyPipelineChanged()
    }
    
    /// LUT 灵敏度拉回 100
    func resetLUTIntensity() {
        tools.setLUTIntensity(100)
        notifyPipelineChanged()
    }
    
    /// 选中转场模版并预览；从关切到有模版时若时长为 0 则拉到默认
    /// - Parameter id: 预设下标
    func selectTransitionOption(_ id: Int) {
        tools.applyTransition(at: id)
        let hasStyle = OFTransitionPreset.all.indices.contains(id) && OFTransitionPreset.all[id].style != nil
        if hasStyle, tools.transitionDurationSlider < 0.5 {
            tools.setTransitionDuration(50)
        }
        notifyPipelineChanged()
    }
    
    /// 拖动转场时长
    /// - Parameter value: 0…100
    func updateTransitionDuration(_ value: Float) {
        tools.setTransitionDuration(value)
        notifyPipelineChanged()
    }
    
    /// 时长滑杆回到默认
    func resetTransitionDuration() {
        tools.resetTransitionDuration()
        notifyPipelineChanged()
    }
    
    /// 选中美肤滤镜；强度为 0 时给默认 50，避免只换风格看不见变化
    /// - Parameter id: 风格 rawValue
    func selectWhiteningOption(_ id: Int) {
        beauty.leaveOneClickKeepingValues()
        beauty.whiteningStyle = OFWhiteningStyle(rawValue: id) ?? .warm
        if beauty.whitening < 0.5 {
            beauty.whitening = 50
        }
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    /// - Parameter value: 0…100
    func updateWhiteningIntensity(_ value: Float) {
        beauty.leaveOneClickKeepingValues()
        beauty.setToneValue(value, for: .whitening)
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 美肤灵敏度归零
    func resetWhiteningIntensity() {
        beauty.leaveOneClickKeepingValues()
        beauty.setToneValue(0, for: .whitening)
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 拖动面部重塑滑杆，即时写入 GPU
    /// - Parameters:
    ///   - key: 六项 ID
    ///   - value: −50…50
    func updateFaceReshape(key: OFFaceReshapeKey, value: Float) {
        beauty.leaveOneClickKeepingValues()
        beauty.setReshapeValue(value, for: key)
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 六项灵敏度归零
    func resetFaceReshape() {
        beauty.leaveOneClickKeepingValues()
        beauty.resetReshape()
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 拖动磨皮 / 美肤 / 亮眼 / 白牙
    /// - Parameters:
    ///   - key: 着色项
    ///   - value: 0…100
    func updateBeautyTone(key: OFBeautyToneKey, value: Float) {
        beauty.leaveOneClickKeepingValues()
        beauty.setToneValue(value, for: key)
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 四项着色归零
    func resetBeautyTone() {
        let wasOneClick = beauty.oneClickEnabled
        beauty.oneClickEnabled = false
        beauty.resetTone()
        if wasOneClick {
            beauty.resetReshape()
        }
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 开关一键美颜：打开套预设，关掉还原打开前的手动值
    func toggleBeautyOneClick() {
        if beauty.oneClickEnabled {
            beauty.disableOneClickRestoreBackup()
        } else {
            beauty.enableOneClickPreset()
        }
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 点了其它子项，一键关掉但参数留着给手动微调
    func leaveBeautyOneClick() {
        beauty.leaveOneClickKeepingValues()
        syncBeautyMaster()
        notifyPipelineChanged()
    }
    
    /// 按住对比看未着色的脸
    /// - Parameter holding: 是否按住
    func setBeautyToneCompareHolding(_ holding: Bool) {
        tools.setBeautyToneBypassed(holding)
        notifyPipelineChanged()
    }
    
    /// 有滑杆或网格时打开总开关，否则关掉以免空跑推理
    private func syncBeautyMaster() {
        beauty.isEnabled = !beauty.isIdentity || !beauty.isReshapeIdentity || tools.isFaceMeshOverlayEnabled
        tools.applyBeautySettings(beauty)
    }
    
    /// 按住对比看未变形的脸
    /// - Parameter holding: 是否按住
    func setFaceReshapeCompareHolding(_ holding: Bool) {
        tools.setFaceReshapeBypassed(holding)
        notifyPipelineChanged()
    }
    
    /// 人脸网格是否在画
    var isFaceMeshOverlayEnabled: Bool {
        return tools.isFaceMeshOverlayEnabled
    }
    
    /// 一键美颜是否打开
    var isBeautyOneClickEnabled: Bool {
        return beauty.oneClickEnabled
    }
    
    /// 拖动调色滑杆
    /// - Parameters:
    ///   - key: 参数 ID
    ///   - value: 滑杆当前值
    func updateColorAdjust(key: OFColorAdjustKey, value: Float) {
        tools.updateColorAdjust(key: key, value: value)
        notifyPipelineChanged()
    }
    
    /// 打开调色页前记下当前值，方便取消
    func beginColorAdjustEditing() {
        colorAdjustBackup = tools.colorAdjustParams
        tools.setColorAdjustBypassed(false)
    }
    
    /// 点 X：还原进入前的参数
    func cancelColorAdjustEditing() {
        if let backup = colorAdjustBackup {
            tools.replaceColorAdjustParams(backup)
        }
        tools.setColorAdjustBypassed(false)
        colorAdjustBackup = nil
    }
    
    /// 点勾：保留当前参数
    func confirmColorAdjustEditing() {
        tools.setColorAdjustBypassed(false)
        colorAdjustBackup = nil
    }
    
    /// 按住对比看原片
    /// - Parameter holding: 是否按住
    func setColorAdjustCompareHolding(_ holding: Bool) {
        tools.setColorAdjustBypassed(holding)
        notifyPipelineChanged()
    }
    
    /// 按住对比时旁路 LUT
    /// - Parameter bypassed: true 看未套 LUT 的画面
    func setLUTBypassed(_ bypassed: Bool) {
        tools.setLUTBypassed(bypassed)
        notifyPipelineChanged()
    }
    
    /// 调色全部复位
    func resetColorAdjust() {
        tools.resetColorAdjust()
        notifyPipelineChanged()
    }
    
    /// 当前镜头位置文案
    /// - Returns: 前置 / 后置 / --
    private func cameraValueText() -> String {
        switch inputDevice?.currentCameraPosition {
        case .front:
            return "前置"
        case .back:
            return "后置"
        default:
            return "--"
        }
    }
}

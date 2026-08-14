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

/// 设置页业务逻辑，不负责动画。
class OFSettingsController {
    /// 滤镜门面
    private let tools: OFAuxiliaryTools
    /// 用来读/切摄像头；未就绪时格子显示「--」
    weak var inputDevice: OFiPhoneInputDevice?
    /// 美颜占位状态
    let beauty = OFBeautySettings()
    
    /// - Parameter tools: 已搭好处理图的门面
    init(tools: OFAuxiliaryTools) {
        self.tools = tools
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
        case .beauty:
            return makeBeautyPage()
        case .colorAdjust:
            return makeColorAdjustPage()
        }
    }
    
    /// 处理格子点击
    /// - Parameter id: 被点中的设置项
    /// - Returns: 刷新当前页或 push 二级页
    func performTap(_ id: OFSettingID) -> OFSettingsTapResult {
        switch id {
        case .camera:
            _ = inputDevice?.switchCameraPosition()
            DDLogInfo("settings camera -> \(cameraValueText())")
            return .reload
        case .lut:
            return .push(.lut)
        case .lutPreset(let index):
            tools.applyLUT(at: index)
            return .reload
        case .singleColor:
            tools.switchSingleColor()
            return .reload
        case .gaussianBlur:
            tools.switchGaussianBlur()
            return .reload
        case .edgeDetection:
            tools.switchPeak()
            return .reload
        case .beauty:
            return .push(.beauty)
        case .colorAdjust:
            return .push(.colorAdjust)
        case .colorParam:
            return .reload
        case .beautyMaster:
            beauty.isEnabled.toggle()
            tools.setBeautyEnabled(beauty.isEnabled)
            DDLogInfo("beauty master \(beauty.isEnabled)")
            return .reload
        case .faceMeshOverlay:
            tools.setFaceMeshOverlayEnabled(!tools.isFaceMeshOverlayEnabled)
            return .reload
        case .beautySmooth:
            beauty.smooth = beauty.smooth.next()
            DDLogInfo("beauty smooth \(beauty.smooth.displayName)，处理图尚未接入")
            return .reload
        case .beautyWhitening:
            beauty.whitening = beauty.whitening.next()
            DDLogInfo("beauty whitening \(beauty.whitening.displayName)，处理图尚未接入")
            return .reload
        }
    }
    
    /// 主卡片：已实现滤镜 + 美颜入口，后续参数往这里追加
    /// - Returns: 根页
    private func makeRootPage() -> OFSettingsPage {
        let items: [OFSettingItem] = [
            OFSettingItem(id: .camera, title: "摄像头", valueText: cameraValueText(), interaction: .cycle),
            OFSettingItem(id: .lut, title: "LUT", valueText: tools.lutValueText, interaction: .drillIn(.lut)),
            OFSettingItem(id: .singleColor, title: "单色", valueText: tools.singleColorValueText, interaction: .cycle),
            OFSettingItem(id: .gaussianBlur, title: "高斯模糊", valueText: tools.isGaussianBlurEnabled ? "开" : "关", interaction: .toggle),
            OFSettingItem(id: .edgeDetection, title: "描边", valueText: tools.isPeakEnabled ? "开" : "关", interaction: .toggle),
            OFSettingItem(id: .beauty, title: "美颜", valueText: beauty.summaryText, interaction: .drillIn(.beauty)),
            OFSettingItem(id: .colorAdjust, title: "调色", valueText: tools.colorAdjustSummary, interaction: .drillIn(.colorAdjust)),
        ]
        return OFSettingsPage(id: .root, title: "设置", items: items)
    }
    
    /// LUT 二级页：点某一项直接选中该预设
    /// - Returns: LUT 页
    private func makeLUTPage() -> OFSettingsPage {
        let current = tools.currentLUTIndex
        var items: [OFSettingItem] = []
        for (index, preset) in OFLUTPreset.all.enumerated() {
            let name = preset.fileName == nil ? "关" : preset.displayName
            let mark = index == current ? "已选" : "—"
            items.append(OFSettingItem(id: .lutPreset(index), title: name, valueText: mark, interaction: .cycle))
        }
        return OFSettingsPage(id: .lut, title: "LUT", items: items)
    }
    
    /// 美颜二级页：总开关和网格接到 Face Landmarker，磨皮/美白仍占位
    /// - Returns: 美颜页
    private func makeBeautyPage() -> OFSettingsPage {
        let items: [OFSettingItem] = [
            OFSettingItem(id: .beautyMaster, title: "美颜", valueText: beauty.isEnabled ? "开" : "关", interaction: .toggle),
            OFSettingItem(id: .faceMeshOverlay, title: "人脸网格", valueText: tools.isFaceMeshOverlayEnabled ? "开" : "关", interaction: .toggle),
            OFSettingItem(id: .beautySmooth, title: "磨皮", valueText: beauty.smooth.displayName, interaction: .cycle),
            OFSettingItem(id: .beautyWhitening, title: "美白", valueText: beauty.whitening.displayName, interaction: .cycle),
        ]
        return OFSettingsPage(id: .beauty, title: "美颜", items: items)
    }
    
    /// 调色二级页：列表滑杆，拖动即写入处理图
    /// - Returns: 滑杆页
    private func makeColorAdjustPage() -> OFSettingsPage {
        return OFSettingsPage(id: .colorAdjust, title: "调色", sliders: tools.colorAdjustSliderRows())
    }
    
    /// 拖动调色滑杆
    /// - Parameters:
    ///   - key: 参数 ID
    ///   - value: 滑杆当前值
    func updateColorAdjust(key: OFColorAdjustKey, value: Float) {
        tools.updateColorAdjust(key: key, value: value)
    }
    
    /// 调色全部复位
    func resetColorAdjust() {
        tools.resetColorAdjust()
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

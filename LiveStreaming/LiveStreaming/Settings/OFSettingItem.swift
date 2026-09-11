//
//  OFSettingItem.swift
//  LiveStreaming
//
//  设置页数据模型：用 ID 描述一项参数，交互方式与具体滤镜解耦，方便后续加美颜等。
//

import Foundation
import OFFilterKit

/// 设置页层级。根页是网格总览，复杂项再 push 二级页。
enum OFSettingsPageID: Equatable {
    /// 底部主卡片
    case root
    /// LUT 预设列表
    case lut
    /// 美颜参数；人脸网格已接入 Face Landmarker
    case beauty
    /// 美肤滤镜：冷白 / 暖白 / 粉嫩
    case whiteningStyle
    /// 面部重塑：瘦脸 / 大眼 / 瘦鼻 / 嘴巴 / 发际线 / 下颌
    case faceReshape
    /// 调色滑杆页
    case colorAdjust
    /// 转场模版 + 时长
    case transition
}

/// 一项设置的稳定 ID，后续扩展只加 case，不要靠下标。
enum OFSettingID: Equatable {
    /// 前后摄像头
    case camera
    /// 主页上的 LUT 入口
    case lut
    /// 二级页里选中某个 LUT 预设
    case lutPreset(Int)
    /// 单通道 / 灰度
    case singleColor
    /// 高斯模糊开关
    case gaussianBlur
    /// Peak 描边开关
    case edgeDetection
    /// 主页上的美颜入口
    case beauty
    /// 美肤页里选中某一档滤镜
    case whiteningStylePreset(OFWhiteningStyle)
    /// 美颜总开关
    case beautyMaster
    /// 人脸网格预览（画 Face Landmarker 点）
    case faceMeshOverlay
    /// 美颜页上的面部重塑入口
    case faceReshape
    /// 主页上的调色入口
    case colorAdjust
    /// 调色滑杆
    case colorParam(OFColorAdjustKey)
    /// 主页上的转场入口
    case transition
    /// 二级页里选中某个转场模版
    case transitionPreset(Int)
}

/// 点击格子后的行为。
enum OFSettingInteraction {
    /// 在开/关之间切换
    case toggle
    /// 在一组离散值里循环
    case cycle
    /// 打开二级卡片
    case drillIn(OFSettingsPageID)
}

/// 网格里展示的一项。
struct OFSettingItem {
    /// 点击时用来分发
    let id: OFSettingID
    /// 格子上方标题
    let title: String
    /// 当前值，灰色小字
    let valueText: String
    /// 点击行为
    let interaction: OFSettingInteraction
}

/// 互斥选项 + 一条灵敏度滑杆（LUT、美肤滤镜）。
struct OFOptionSliderPage {
    /// 横向图标
    let options: [OFOptionSliderRow]
    /// 当前选中项 id
    let selectedID: Int
    /// 灵敏度 0…100
    let intensity: Float
    /// 选「关」时滑杆不可用
    let intensityEnabled: Bool
}

/// 互斥选项里的一项。
struct OFOptionSliderRow {
    /// 稳定 id：LUT 用预设下标，美肤用风格 rawValue
    let id: Int
    /// 图标下标题
    let title: String
}

/// 一张设置卡片的内容。
struct OFSettingsPage {
    /// 页标识，用于导航栈
    let id: OFSettingsPageID
    /// 卡片顶部标题
    let title: String
    /// 四宫格格子；滑杆页可为空
    let items: [OFSettingItem]
    /// 调色页滑杆；空表示网格布局
    let sliders: [OFColorSliderRow]
    /// 面部重塑滑杆；空表示不用重塑编辑器
    let reshapeSliders: [OFFaceReshapeSliderRow]
    /// 美颜着色滑杆；空表示不用美颜编辑器
    let beautySliders: [OFBeautySliderRow]
    /// LUT / 美肤滤镜：互斥选项 + 一条灵敏度滑杆
    let optionSlider: OFOptionSliderPage?
    
    /// 网格页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - items: 格子
    init(id: OFSettingsPageID, title: String, items: [OFSettingItem]) {
        self.id = id
        self.title = title
        self.items = items
        self.sliders = []
        self.reshapeSliders = []
        self.beautySliders = []
        self.optionSlider = nil
    }
    
    /// 调色滑杆页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - sliders: 滑杆行
    init(id: OFSettingsPageID, title: String, sliders: [OFColorSliderRow]) {
        self.id = id
        self.title = title
        self.items = []
        self.sliders = sliders
        self.reshapeSliders = []
        self.beautySliders = []
        self.optionSlider = nil
    }
    
    /// 面部重塑滑杆页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - reshapeSliders: 六项灵敏度
    init(id: OFSettingsPageID, title: String, reshapeSliders: [OFFaceReshapeSliderRow]) {
        self.id = id
        self.title = title
        self.items = []
        self.sliders = []
        self.reshapeSliders = reshapeSliders
        self.beautySliders = []
        self.optionSlider = nil
    }
    
    /// 美颜着色滑杆页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - beautySliders: 一键 / 网格 / 重塑 / 磨皮等
    init(id: OFSettingsPageID, title: String, beautySliders: [OFBeautySliderRow]) {
        self.id = id
        self.title = title
        self.items = []
        self.sliders = []
        self.reshapeSliders = []
        self.beautySliders = beautySliders
        self.optionSlider = nil
    }
    
    /// LUT / 美肤：横向互斥选项 + 灵敏度滑杆，对齐调色页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - optionSlider: 选项和当前灵敏度
    init(id: OFSettingsPageID, title: String, optionSlider: OFOptionSliderPage) {
        self.id = id
        self.title = title
        self.items = []
        self.sliders = []
        self.reshapeSliders = []
        self.beautySliders = []
        self.optionSlider = optionSlider
    }
    
    /// 是否用调色滑杆而不是四宫格
    var usesSliders: Bool {
        return !sliders.isEmpty
    }
}

/// 处理一次点击后，UI 该刷新还是推入子页。
enum OFSettingsTapResult {
    /// 当前页数据变了，重绘格子
    case reload
    /// 打开二级页
    case push(OFSettingsPageID)
}

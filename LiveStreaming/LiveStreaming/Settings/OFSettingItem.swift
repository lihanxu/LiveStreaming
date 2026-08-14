//
//  OFSettingItem.swift
//  LiveStreaming
//
//  设置页数据模型：用 ID 描述一项参数，交互方式与具体滤镜解耦，方便后续加美颜等。
//

import Foundation

/// 设置页层级。根页是网格总览，复杂项再 push 二级页。
enum OFSettingsPageID: Equatable {
    /// 底部主卡片
    case root
    /// LUT 预设列表
    case lut
    /// 美颜参数；人脸网格已接入 Face Landmarker
    case beauty
    /// 调色滑杆页
    case colorAdjust
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
    /// 美颜总开关
    case beautyMaster
    /// 人脸网格预览（画 Face Landmarker 点）
    case faceMeshOverlay
    /// 磨皮档位
    case beautySmooth
    /// 美白档位
    case beautyWhitening
    /// 亮眼档位
    case beautyBrightEyes
    /// 白牙档位
    case beautyWhiteTeeth
    /// 主页上的调色入口
    case colorAdjust
    /// 调色滑杆
    case colorParam(OFColorAdjustKey)
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
    }
    
    /// 滑杆页
    /// - Parameters:
    ///   - id: 页 ID
    ///   - title: 标题
    ///   - sliders: 滑杆行
    init(id: OFSettingsPageID, title: String, sliders: [OFColorSliderRow]) {
        self.id = id
        self.title = title
        self.items = []
        self.sliders = sliders
    }
    
    /// 是否用滑杆列表而不是四宫格
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

/// 美颜档位，关/低/中/高对应 GPU 强度 0…1。
enum OFBeautyLevel: Int, CaseIterable {
    /// 关闭
    case off = 0
    /// 低
    case low
    /// 中
    case medium
    /// 高
    case high
    
    /// 设置页展示文案
    var displayName: String {
        switch self {
        case .off:
            return "关"
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        }
    }
    
    /// 循环到下一档
    /// - Returns: 下一档，高之后回到关
    func next() -> OFBeautyLevel {
        return OFBeautyLevel(rawValue: rawValue + 1) ?? .off
    }
    
    /// 写入 GPU 的强度，0…1
    var gpuStrength: Float {
        switch self {
        case .off:
            return 0
        case .low:
            return 0.45
        case .medium:
            return 0.75
        case .high:
            return 1.0
        }
    }
}

/// 美颜参数状态，接到处理图时读这些档位。
class OFBeautySettings {
    /// 总开关；关闭时不跑美颜 kernel，也不强制推理
    var isEnabled = false
    /// 磨皮
    var smooth: OFBeautyLevel = .off
    /// 美白
    var whitening: OFBeautyLevel = .off
    /// 亮眼
    var brightEyes: OFBeautyLevel = .off
    /// 白牙
    var whiteTeeth: OFBeautyLevel = .off
    
    /// 主页上美颜格子的当前值
    var summaryText: String {
        return isEnabled ? "开" : "关"
    }
    
    /// 四项强度都为 0 时 GPU 可跳过合成
    var isIdentity: Bool {
        return smooth.gpuStrength < 0.001
            && whitening.gpuStrength < 0.001
            && brightEyes.gpuStrength < 0.001
            && whiteTeeth.gpuStrength < 0.001
    }
}

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
    /// 美颜参数（处理图尚未接入，先占位）
    case beauty
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
    /// 磨皮档位（占位）
    case beautySmooth
    /// 美白档位（占位）
    case beautyWhitening
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
    /// 按行优先排列的格子；不足 4 的倍数时末尾留空
    let items: [OFSettingItem]
}

/// 处理一次点击后，UI 该刷新还是推入子页。
enum OFSettingsTapResult {
    /// 当前页数据变了，重绘格子
    case reload
    /// 打开二级页
    case push(OFSettingsPageID)
}

/// 美颜档位占位，GPU 接入前只改文案。
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
}

/// 美颜参数占位状态，后续接到处理图时直接读这些值。
class OFBeautySettings {
    /// 总开关
    var isEnabled = false
    /// 磨皮
    var smooth: OFBeautyLevel = .off
    /// 美白
    var whitening: OFBeautyLevel = .off
    
    /// 主页上美颜格子的当前值
    var summaryText: String {
        return isEnabled ? "开" : "关"
    }
}

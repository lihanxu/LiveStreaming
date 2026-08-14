//
//  OFColorAdjustParams.swift
//  LiveStreaming
//
//  调色滑杆参数。数值与设置页一致，打包顺序必须和 Metal ColorAdjustParams 对齐。
//

import Foundation

/// 每一项调色滑杆的稳定 ID。
enum OFColorAdjustKey: String, CaseIterable {
    case exposure
    case highlights
    case shadows
    case contrast
    case brightness
    case blacks
    case saturation
    case vibrance
    case temperature
    case tint
    case sharpen
    case clarity
    case fade
    case vignette
    
    /// 设置页标题
    var title: String {
        switch self {
        case .exposure: return "曝光"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .contrast: return "对比度"
        case .brightness: return "亮度"
        case .blacks: return "黑点"
        case .saturation: return "饱和度"
        case .vibrance: return "自然饱和度"
        case .temperature: return "色温"
        case .tint: return "色调"
        case .sharpen: return "锐化"
        case .clarity: return "清晰度"
        case .fade: return "褪色"
        case .vignette: return "暗角"
        }
    }
    
    /// 滑杆最小值
    var minimum: Float {
        switch self {
        case .sharpen, .fade, .vignette:
            return 0
        default:
            return -50
        }
    }
    
    /// 滑杆最大值
    var maximum: Float {
        switch self {
        case .sharpen, .fade, .vignette:
            return 100
        default:
            return 50
        }
    }
}

/// 二级页一行滑杆的展示数据。
struct OFColorSliderRow {
    /// 对应参数
    let key: OFColorAdjustKey
    /// 标题
    let title: String
    /// 当前值
    let value: Float
    /// 滑杆下限
    let minimum: Float
    /// 滑杆上限
    let maximum: Float
}

/// 调色状态，默认全 0 表示关闭节点。
struct OFColorAdjustParams {
    /// 曝光 −50…50
    var exposure: Float = 0
    /// 高光 −50…50
    var highlights: Float = 0
    /// 阴影 −50…50
    var shadows: Float = 0
    /// 对比度 −50…50
    var contrast: Float = 0
    /// 亮度 −50…50
    var brightness: Float = 0
    /// 黑点 −50…50
    var blacks: Float = 0
    /// 饱和度 −50…50
    var saturation: Float = 0
    /// 自然饱和度 −50…50
    var vibrance: Float = 0
    /// 色温 −50…50
    var temperature: Float = 0
    /// 色调 −50…50
    var tint: Float = 0
    /// 锐化 0…100
    var sharpen: Float = 0
    /// 清晰度 −50…50
    var clarity: Float = 0
    /// 褪色 0…100
    var fade: Float = 0
    /// 暗角 0…100
    var vignette: Float = 0
    
    /// 全部为默认值时不跑 GPU
    var isIdentity: Bool {
        return gpuPacked().allSatisfy { abs($0) < 0.001 }
    }
    
    /// 是否需要邻域 pass（锐化 / 清晰度 / 暗角）
    var needsSpatialPass: Bool {
        return abs(sharpen) > 0.001 || abs(clarity) > 0.001 || abs(vignette) > 0.001
    }
    
    /// 根页摘要
    var summaryText: String {
        return isIdentity ? "默认" : "已调"
    }
    
    /// 读取某一项
    /// - Parameter key: 滑杆 ID
    /// - Returns: 当前值
    func value(for key: OFColorAdjustKey) -> Float {
        switch key {
        case .exposure: return exposure
        case .highlights: return highlights
        case .shadows: return shadows
        case .contrast: return contrast
        case .brightness: return brightness
        case .blacks: return blacks
        case .saturation: return saturation
        case .vibrance: return vibrance
        case .temperature: return temperature
        case .tint: return tint
        case .sharpen: return sharpen
        case .clarity: return clarity
        case .fade: return fade
        case .vignette: return vignette
        }
    }
    
    /// 写入某一项
    /// - Parameters:
    ///   - key: 滑杆 ID
    ///   - value: 新值
    mutating func setValue(_ value: Float, for key: OFColorAdjustKey) {
        let clamped = min(key.maximum, max(key.minimum, value))
        switch key {
        case .exposure: exposure = clamped
        case .highlights: highlights = clamped
        case .shadows: shadows = clamped
        case .contrast: contrast = clamped
        case .brightness: brightness = clamped
        case .blacks: blacks = clamped
        case .saturation: saturation = clamped
        case .vibrance: vibrance = clamped
        case .temperature: temperature = clamped
        case .tint: tint = clamped
        case .sharpen: sharpen = clamped
        case .clarity: clarity = clamped
        case .fade: fade = clamped
        case .vignette: vignette = clamped
        }
    }
    
    /// 按 Metal 结构体顺序打包
    /// - Returns: 14 个 float
    func gpuPacked() -> [Float] {
        return [
            exposure, highlights, shadows, contrast,
            brightness, blacks, saturation, vibrance,
            temperature, tint, sharpen, clarity,
            fade, vignette
        ]
    }
    
    /// 二级页全部滑杆
    /// - Returns: 按显示顺序的行
    func sliderRows() -> [OFColorSliderRow] {
        return OFColorAdjustKey.allCases.map { key in
            OFColorSliderRow(key: key, title: key.title, value: value(for: key), minimum: key.minimum, maximum: key.maximum)
        }
    }
}

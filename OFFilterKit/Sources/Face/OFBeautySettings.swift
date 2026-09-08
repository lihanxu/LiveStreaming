//
//  OFBeautySettings.swift
//  LiveStreaming
//
//  美颜 / 重塑参数 DTO：给滤镜内核与设置页共用，不含 UI 布局。
//

import Foundation

/// 美肤滤镜：冷白 / 暖白 / 粉嫩，对应 LUT PNG。
public enum OFWhiteningStyle: Int, CaseIterable {
    /// 暖白：提亮并保留黄桃底
    case warm = 0
    /// 冷白：去黄、偏瓷白
    case cold = 1
    /// 粉嫩：中灰加很轻的品红
    case pink = 2

    /// 二级页按钮标题
    public var title: String {
        switch self {
        case .warm: return "暖白"
        case .cold: return "冷白"
        case .pink: return "粉嫩"
        }
    }

    /// Bundle 中 512×512 LUT PNG 名（不含扩展名）
    public var lutFileName: String {
        switch self {
        case .warm: return "SkinWarmWhite"
        case .cold: return "SkinCoolWhite"
        case .pink: return "SkinPink"
        }
    }
}

/// 美颜着色滑杆 ID。
public enum OFBeautyToneKey: String, CaseIterable {
    /// 磨皮
    case smooth
    /// 美肤（LUT 混合）
    case whitening
    /// 亮眼
    case brightEyes
    /// 白牙
    case whiteTeeth

    /// 设置页标题
    public var title: String {
        switch self {
        case .smooth: return "磨皮"
        case .whitening: return "美肤"
        case .brightEyes: return "亮眼"
        case .whiteTeeth: return "白牙"
        }
    }
}

/// 美颜面板图标：四项滑杆 + 网格开关 + 进入重塑。
public enum OFBeautyPanelKey: String, CaseIterable {
    /// 一键套用最优参数，与手动滑杆互斥
    case oneClick
    /// 人脸网格预览
    case faceMesh
    /// 进入面部重塑
    case faceReshape
    /// 磨皮
    case smooth
    /// 美肤（LUT 混合）
    case whitening
    /// 亮眼
    case brightEyes
    /// 白牙
    case whiteTeeth

    /// 设置页标题
    public var title: String {
        switch self {
        case .oneClick: return "一键"
        case .smooth: return "磨皮"
        case .whitening: return "美肤"
        case .brightEyes: return "亮眼"
        case .whiteTeeth: return "白牙"
        case .faceMesh: return "网格"
        case .faceReshape: return "重塑"
        }
    }

    /// 是否对应 0…100 滑杆
    public var usesSlider: Bool {
        switch self {
        case .smooth, .brightEyes, .whiteTeeth:
            return true
        case .oneClick, .faceMesh, .faceReshape, .whitening:
            return false
        }
    }

    /// 对应着色滑杆；网格/重塑为 nil
    public var toneKey: OFBeautyToneKey? {
        switch self {
        case .smooth: return .smooth
        case .whitening: return .whitening
        case .brightEyes: return .brightEyes
        case .whiteTeeth: return .whiteTeeth
        case .faceMesh, .faceReshape, .oneClick: return nil
        }
    }
}

/// 美颜页一行图标数据。
public struct OFBeautySliderRow {
    /// 面板项
    public let key: OFBeautyPanelKey
    /// 标题
    public let title: String
    /// 当前值；滑杆项 0…100
    public let value: Float
    /// 滑杆下限
    public let minimum: Float
    /// 滑杆上限
    public let maximum: Float

    /// 构造一行美颜面板数据
    public init(key: OFBeautyPanelKey, title: String, value: Float, minimum: Float, maximum: Float) {
        self.key = key
        self.title = title
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// 美颜参数状态：着色 0…100，重塑 −50…50。
public class OFBeautySettings {
    /// 默认空参数
    public init() {}

    /// 总开关；关闭时不跑美颜 / 重塑 kernel
    public var isEnabled = false
    /// 磨皮，滑杆 0…100
    public var smooth: Float = 0
    /// 美肤强度，滑杆 0…100，写入 GPU 后作为 LUT mix
    public var whitening: Float = 0
    /// 当前美肤滤镜；强度为 0 时不套色表
    public var whiteningStyle: OFWhiteningStyle = .warm
    /// 亮眼，滑杆 0…100；写入 GPU 时再乘 1.5
    public var brightEyes: Float = 0
    /// 白牙，滑杆 0…100；写入 GPU 时再乘 1.5
    public var whiteTeeth: Float = 0
    /// 瘦脸，滑杆 −50…50，正瘦负胖
    public var slimFace: Float = 0
    /// 大眼，滑杆 −50…50，正放大负缩小
    public var bigEye: Float = 0
    /// 瘦鼻，滑杆 −50…50，正瘦负宽
    public var slimNose: Float = 0
    /// 嘴巴，滑杆 −50…50，正放大负缩小
    public var mouth: Float = 0
    /// 发际线，滑杆 −50…50，正上移负下移
    public var hairline: Float = 0
    /// 下颌，滑杆 −50…50，正内收负外扩
    public var jaw: Float = 0
    /// 一键美颜是否打开；打开时用预设，手动改任一子项会关掉
    public var oneClickEnabled = false
    /// 打开一键前的着色备份，关掉一键时还原
    private var backupSmooth: Float = 0
    /// 打开一键前的美肤强度备份
    private var backupWhitening: Float = 0
    /// 打开一键前的美肤滤镜备份
    private var backupWhiteningStyle: OFWhiteningStyle = .warm
    /// 打开一键前的亮眼备份
    private var backupBrightEyes: Float = 0
    /// 打开一键前的白牙备份
    private var backupWhiteTeeth: Float = 0
    /// 打开一键前的瘦脸备份
    private var backupSlimFace: Float = 0
    /// 打开一键前的大眼备份
    private var backupBigEye: Float = 0
    /// 打开一键前的瘦鼻备份
    private var backupSlimNose: Float = 0
    /// 打开一键前的嘴巴备份
    private var backupMouth: Float = 0
    /// 打开一键前的发际线备份
    private var backupHairline: Float = 0
    /// 打开一键前的下颌备份
    private var backupJaw: Float = 0

    /// 主页上美颜格子的当前值
    public var summaryText: String {
        return isEnabled ? "开" : "关"
    }

    /// 面部重塑摘要
    public var reshapeSummaryText: String {
        return isReshapeIdentity ? "关" : "已调"
    }

    /// 四项着色都为 0 时着色 GPU 可跳过
    public var isIdentity: Bool {
        return smooth < 0.5
            && whitening < 0.5
            && brightEyes < 0.5
            && whiteTeeth < 0.5
    }

    /// 六项形变都接近 0 时 warp GPU 可跳过
    public var isReshapeIdentity: Bool {
        return abs(slimFace) < 0.5
            && abs(bigEye) < 0.5
            && abs(slimNose) < 0.5
            && abs(mouth) < 0.5
            && abs(hairline) < 0.5
            && abs(jaw) < 0.5
    }

    /// 着色滑杆写成 GPU 强度。美肤与滑杆 1:1；亮眼/白牙上限加半。
    /// - Parameters:
    ///   - slider: 0…100
    ///   - key: 着色项
    /// - Returns: 写入 kernel 的强度
    public static func toneGpuStrength(_ slider: Float, key: OFBeautyToneKey) -> Float {
        let unit = min(1, max(0, slider / 100))
        switch key {
        case .smooth, .whitening:
            return unit
        case .brightEyes, .whiteTeeth:
            return unit * 1.5
        }
    }

    /// 重塑滑杆写成 GPU −1…1，正负表示方向
    /// - Parameter slider: −50…50
    /// - Returns: 写入 kernel 的有符号强度
    public static func reshapeGpuStrength(_ slider: Float) -> Float {
        return min(1, max(-1, slider / 50))
    }

    /// 读取着色滑杆
    /// - Parameter key: 四项 ID
    /// - Returns: 0…100
    public func toneValue(for key: OFBeautyToneKey) -> Float {
        switch key {
        case .smooth: return smooth
        case .whitening: return whitening
        case .brightEyes: return brightEyes
        case .whiteTeeth: return whiteTeeth
        }
    }

    /// 写入着色滑杆
    /// - Parameters:
    ///   - key: 四项 ID
    ///   - value: 0…100
    public func setToneValue(_ value: Float, for key: OFBeautyToneKey) {
        let clamped = min(100, max(0, value))
        switch key {
        case .smooth: smooth = clamped
        case .whitening: whitening = clamped
        case .brightEyes: brightEyes = clamped
        case .whiteTeeth: whiteTeeth = clamped
        }
    }

    /// 四项着色归零
    public func resetTone() {
        smooth = 0
        whitening = 0
        brightEyes = 0
        whiteTeeth = 0
    }

    /// 美颜页图标数据（含一键 / 网格 / 重塑入口）
    /// - Parameter meshOn: 人脸网格是否打开
    /// - Returns: 面板行
    public func beautySliderRows(meshOn: Bool) -> [OFBeautySliderRow] {
        return OFBeautyPanelKey.allCases.map { key in
            if let tone = key.toneKey {
                let title = key == .whitening ? whiteningStyle.title : key.title
                return OFBeautySliderRow(key: key, title: title, value: toneValue(for: tone), minimum: 0, maximum: 100)
            }
            let flag: Float
            if key == .faceMesh && meshOn {
                flag = 1
            } else if key == .oneClick && oneClickEnabled {
                flag = 1
            } else {
                flag = 0
            }
            return OFBeautySliderRow(key: key, title: key.title, value: flag, minimum: 0, maximum: 1)
        }
    }

    /// 读取某一项重塑滑杆
    /// - Parameter key: 六项 ID
    /// - Returns: −50…50
    public func reshapeValue(for key: OFFaceReshapeKey) -> Float {
        switch key {
        case .slimFace: return slimFace
        case .bigEye: return bigEye
        case .slimNose: return slimNose
        case .mouth: return mouth
        case .hairline: return hairline
        case .jaw: return jaw
        }
    }

    /// 写入某一项重塑滑杆
    /// - Parameters:
    ///   - key: 六项 ID
    ///   - value: −50…50
    public func setReshapeValue(_ value: Float, for key: OFFaceReshapeKey) {
        let clamped = min(50, max(-50, value))
        switch key {
        case .slimFace: slimFace = clamped
        case .bigEye: bigEye = clamped
        case .slimNose: slimNose = clamped
        case .mouth: mouth = clamped
        case .hairline: hairline = clamped
        case .jaw: jaw = clamped
        }
    }

    /// 六项全部归零
    public func resetReshape() {
        slimFace = 0
        bigEye = 0
        slimNose = 0
        mouth = 0
        hairline = 0
        jaw = 0
    }

    /// 重塑页滑杆数据，范围 −50…50
    /// - Returns: 按显示顺序的行
    public func reshapeSliderRows() -> [OFFaceReshapeSliderRow] {
        return OFFaceReshapeKey.allCases.map { key in
            OFFaceReshapeSliderRow(key: key, title: key.title, value: reshapeValue(for: key), minimum: -50, maximum: 50)
        }
    }

    /// 记下当前手动参数，再套一键预设
    public func enableOneClickPreset() {
        backupSmooth = smooth
        backupWhitening = whitening
        backupWhiteningStyle = whiteningStyle
        backupBrightEyes = brightEyes
        backupWhiteTeeth = whiteTeeth
        backupSlimFace = slimFace
        backupBigEye = bigEye
        backupSlimNose = slimNose
        backupMouth = mouth
        backupHairline = hairline
        backupJaw = jaw
        applyOneClickPreset()
        oneClickEnabled = true
    }

    /// 关掉一键并还原打开前的手动参数
    public func disableOneClickRestoreBackup() {
        oneClickEnabled = false
        smooth = backupSmooth
        whitening = backupWhitening
        whiteningStyle = backupWhiteningStyle
        brightEyes = backupBrightEyes
        whiteTeeth = backupWhiteTeeth
        slimFace = backupSlimFace
        bigEye = backupBigEye
        slimNose = backupSlimNose
        mouth = backupMouth
        hairline = backupHairline
        jaw = backupJaw
    }

    /// 用户改了子项：退出一键模式，但保留当前数值当手动值
    public func leaveOneClickKeepingValues() {
        oneClickEnabled = false
    }

    /// 直播向的中等预设：磨皮明显、美肤克制、轻量形变
    private func applyOneClickPreset() {
        smooth = 55
        whitening = 38
        whiteningStyle = .warm
        brightEyes = 34
        whiteTeeth = 28
        slimFace = 16
        bigEye = 22
        slimNose = 10
        mouth = 8
        hairline = 6
        jaw = 12
    }
}

/// 面部重塑滑杆 ID。
public enum OFFaceReshapeKey: String, CaseIterable {
    /// 瘦脸
    case slimFace
    /// 大眼
    case bigEye
    /// 瘦鼻
    case slimNose
    /// 嘴巴
    case mouth
    /// 发际线
    case hairline
    /// 下颌
    case jaw

    /// 设置页标题
    public var title: String {
        switch self {
        case .slimFace: return "瘦脸"
        case .bigEye: return "大眼"
        case .slimNose: return "瘦鼻"
        case .mouth: return "嘴巴"
        case .hairline: return "发际线"
        case .jaw: return "下颌"
        }
    }
}

/// 面部重塑页一行滑杆。
public struct OFFaceReshapeSliderRow {
    /// 对应参数
    public let key: OFFaceReshapeKey
    /// 标题
    public let title: String
    /// 当前值 −50…50
    public let value: Float
    /// 滑杆下限
    public let minimum: Float
    /// 滑杆上限
    public let maximum: Float

    /// 构造一行重塑滑杆数据
    public init(key: OFFaceReshapeKey, title: String, value: Float, minimum: Float, maximum: Float) {
        self.key = key
        self.title = title
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
    }
}

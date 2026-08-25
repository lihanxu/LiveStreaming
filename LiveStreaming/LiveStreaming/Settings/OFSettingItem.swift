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
    /// 漫画风预设列表
    case cartoon
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
    /// 主页上的漫画风入口
    case cartoon
    /// 二级页里选中某个漫画风预设
    case cartoonPreset(Int)
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

/// 美肤滤镜：冷白 / 暖白 / 粉嫩，对应 Resource/LUT 下三张色表。
enum OFWhiteningStyle: Int, CaseIterable {
    /// 暖白：提亮并保留黄桃底
    case warm = 0
    /// 冷白：去黄、偏瓷白
    case cold = 1
    /// 粉嫩：中灰加很轻的品红
    case pink = 2
    
    /// 二级页按钮标题
    var title: String {
        switch self {
        case .warm: return "暖白"
        case .cold: return "冷白"
        case .pink: return "粉嫩"
        }
    }
    
    /// Bundle 中 512×512 LUT PNG 名（不含扩展名）
    var lutFileName: String {
        switch self {
        case .warm: return "SkinWarmWhite"
        case .cold: return "SkinCoolWhite"
        case .pink: return "SkinPink"
        }
    }
}

/// 美颜着色滑杆 ID。
enum OFBeautyToneKey: String, CaseIterable {
    /// 磨皮
    case smooth
    /// 美肤（LUT 混合）
    case whitening
    /// 亮眼
    case brightEyes
    /// 白牙
    case whiteTeeth
    
    /// 设置页标题
    var title: String {
        switch self {
        case .smooth: return "磨皮"
        case .whitening: return "美肤"
        case .brightEyes: return "亮眼"
        case .whiteTeeth: return "白牙"
        }
    }
}

/// 美颜面板图标：四项滑杆 + 网格开关 + 进入重塑。
enum OFBeautyPanelKey: String, CaseIterable {
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
    var title: String {
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
    var usesSlider: Bool {
        switch self {
        case .smooth, .brightEyes, .whiteTeeth:
            return true
        case .oneClick, .faceMesh, .faceReshape, .whitening:
            return false
        }
    }
    
    /// 对应着色滑杆；网格/重塑为 nil
    var toneKey: OFBeautyToneKey? {
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
struct OFBeautySliderRow {
    /// 面板项
    let key: OFBeautyPanelKey
    /// 标题
    let title: String
    /// 当前值；滑杆项 0…100
    let value: Float
    /// 滑杆下限
    let minimum: Float
    /// 滑杆上限
    let maximum: Float
}

/// 处理一次点击后，UI 该刷新还是推入子页。
enum OFSettingsTapResult {
    /// 当前页数据变了，重绘格子
    case reload
    /// 打开二级页
    case push(OFSettingsPageID)
}

/// 美颜参数状态：着色 0…100，重塑 −50…50。
class OFBeautySettings {
    /// 总开关；关闭时不跑美颜 / 重塑 kernel。由滑杆和网格自动同步。
    var isEnabled = false
    /// 磨皮，滑杆 0…100
    var smooth: Float = 0
    /// 美肤强度，滑杆 0…100，写入 GPU 后作为 LUT mix
    var whitening: Float = 0
    /// 当前美肤滤镜；强度为 0 时不套色表
    var whiteningStyle: OFWhiteningStyle = .warm
    /// 亮眼，滑杆 0…100；写入 GPU 时再乘 1.5
    var brightEyes: Float = 0
    /// 白牙，滑杆 0…100；写入 GPU 时再乘 1.5
    var whiteTeeth: Float = 0
    /// 瘦脸，滑杆 −50…50，正瘦负胖
    var slimFace: Float = 0
    /// 大眼，滑杆 −50…50，正放大负缩小
    var bigEye: Float = 0
    /// 瘦鼻，滑杆 −50…50，正瘦负宽
    var slimNose: Float = 0
    /// 嘴巴，滑杆 −50…50，正放大负缩小
    var mouth: Float = 0
    /// 发际线，滑杆 −50…50，正上移负下移
    var hairline: Float = 0
    /// 下颌，滑杆 −50…50，正内收负外扩
    var jaw: Float = 0
    /// 一键美颜是否打开；打开时用预设，手动改任一子项会关掉
    var oneClickEnabled = false
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
    var summaryText: String {
        return isEnabled ? "开" : "关"
    }
    
    /// 面部重塑摘要
    var reshapeSummaryText: String {
        return isReshapeIdentity ? "关" : "已调"
    }
    
    /// 四项着色都为 0 时着色 GPU 可跳过
    var isIdentity: Bool {
        return smooth < 0.5
            && whitening < 0.5
            && brightEyes < 0.5
            && whiteTeeth < 0.5
    }
    
    /// 六项形变都接近 0 时 warp GPU 可跳过
    var isReshapeIdentity: Bool {
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
    static func toneGpuStrength(_ slider: Float, key: OFBeautyToneKey) -> Float {
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
    static func reshapeGpuStrength(_ slider: Float) -> Float {
        return min(1, max(-1, slider / 50))
    }
    
    /// 读取着色滑杆
    /// - Parameter key: 四项 ID
    /// - Returns: 0…100
    func toneValue(for key: OFBeautyToneKey) -> Float {
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
    func setToneValue(_ value: Float, for key: OFBeautyToneKey) {
        let clamped = min(100, max(0, value))
        switch key {
        case .smooth: smooth = clamped
        case .whitening: whitening = clamped
        case .brightEyes: brightEyes = clamped
        case .whiteTeeth: whiteTeeth = clamped
        }
    }
    
    /// 四项着色归零
    func resetTone() {
        smooth = 0
        whitening = 0
        brightEyes = 0
        whiteTeeth = 0
    }
    
    /// 美颜页图标数据（含一键 / 网格 / 重塑入口）
    /// - Parameter meshOn: 人脸网格是否打开
    /// - Returns: 面板行
    func beautySliderRows(meshOn: Bool) -> [OFBeautySliderRow] {
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
    func reshapeValue(for key: OFFaceReshapeKey) -> Float {
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
    func setReshapeValue(_ value: Float, for key: OFFaceReshapeKey) {
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
    func resetReshape() {
        slimFace = 0
        bigEye = 0
        slimNose = 0
        mouth = 0
        hairline = 0
        jaw = 0
    }
    
    /// 重塑页滑杆数据，范围 −50…50
    /// - Returns: 按显示顺序的行
    func reshapeSliderRows() -> [OFFaceReshapeSliderRow] {
        return OFFaceReshapeKey.allCases.map { key in
            OFFaceReshapeSliderRow(key: key, title: key.title, value: reshapeValue(for: key), minimum: -50, maximum: 50)
        }
    }
    
    /// 记下当前手动参数，再套一键预设
    func enableOneClickPreset() {
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
    func disableOneClickRestoreBackup() {
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
    func leaveOneClickKeepingValues() {
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
enum OFFaceReshapeKey: String, CaseIterable {
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
    var title: String {
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
struct OFFaceReshapeSliderRow {
    /// 对应参数
    let key: OFFaceReshapeKey
    /// 标题
    let title: String
    /// 当前值 −50…50
    let value: Float
    /// 滑杆下限
    let minimum: Float
    /// 滑杆上限
    let maximum: Float
}

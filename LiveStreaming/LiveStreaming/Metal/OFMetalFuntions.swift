//
//  OFMetalFuntions.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  底部功能按钮枚举，rawValue 即默认文案。
//

import Foundation

/// Metal 辅助功能集合（命名沿用历史拼写 Funstions）。
class OFMetalFuntions: NSObject {
    /// 预览底部可点的功能项，顺序即按钮顺序
    enum Funstions: String, CaseIterable {
        /// 切换前后摄像头
        case SwitchCamera = "Switch Camera"
        /// LUT 预设循环
        case LUT = "LUT"
        /// 单通道 / 灰度
        case SingleColor = "Single Color"
        /// 高斯模糊开关
        case GaussianBlur = "Gaussian Blur"
        /// Peak 边缘检测开关
        case EdgeDetection = "Edge Detection"
    }
}

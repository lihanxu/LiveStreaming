//
//  OFProcessNode.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  处理图节点约定：图结构只存 ID，真正做 GPU/滤镜的对象通过 OFProcessNode 注册。
//

import Foundation

/// 处理图顶点 ID。source / sink 只占位，不挂处理器。
enum OFProcessNodeID: String, Hashable {
    /// 采集入口（无处理器）
    case source
    /// 3D LUT 调色
    case lut
    /// 单通道 / 灰度
    case singleColor
    /// 高斯模糊
    case gaussianBlur
    /// 边缘检测（Peak）
    case peak
    /// MediaPipe 人脸网格（美颜底座）
    case faceLandmarker
    /// 预览/编码出口（无处理器，由 ViewController 继续处理）
    case sink
    /// 全局调色（曝光、对比、色温等）
    case colorAdjust
    /// 美颜（磨皮、美白、亮眼、白牙）
    case beauty
}

/// 可插入处理图的滤镜节点。
protocol OFProcessNode: AnyObject {
    /// false 时图调度器跳过，帧原样传给下游
    var isEnabled: Bool { get }
    /// 原地更新 frame.pixelBuffer / frame.texture
    func process(_ frame: VideoFrame)
}

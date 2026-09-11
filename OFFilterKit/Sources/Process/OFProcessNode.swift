//
//  OFProcessNode.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  处理图节点约定：图结构只存 ID，真正做 GPU/滤镜的对象通过 OFProcessNode 注册。
//

import Foundation

/// 处理图顶点 ID。source / sink 只占位，不挂处理器。
public enum OFProcessNodeID: String, Hashable {
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
    /// 预览/编码出口（无处理器，由宿主继续处理）
    case sink
    /// 全局调色（曝光、对比、色温等）
    case colorAdjust
    /// 美颜（磨皮、美肤 LUT、亮眼、白牙）
    case beauty
    /// 面部重塑（瘦脸、大眼、瘦鼻、嘴巴、发际线、下颌）
    case faceReshape
    /// 场景转场（冻结旧画面再按模版混入当前帧）
    case transition
}

/// 可插入处理图的滤镜节点。
public protocol OFProcessNode: AnyObject {
    /// false 时图调度器跳过，帧原样传给下游
    var isEnabled: Bool { get }
    /// 原地更新 frame.pixelBuffer / frame.texture
    func process(_ frame: VideoFrame)
}

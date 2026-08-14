//
//  OFProcessGraph.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//
//  把 SCListGraph 包一层：ID 构图，processor 表执行。
//  拓扑序只在加节点/加边后失效，按帧处理时复用缓存，避免每帧跑 Kahn。
//

import Foundation
import CocoaLumberjack

/// 视频处理 DAG 调度器。
class OFProcessGraph {
    /// 仅存节点 ID 与依赖边
    private let graph = SCListGraph<OFProcessNodeID>()
    /// ID -> 实际滤镜实现；source/sink 不注册
    private var processors: [OFProcessNodeID: OFProcessNode] = [:]
    /// 上次构图后的拓扑序缓存；构图变化时置 nil
    private var cachedOrder: [OFProcessNodeID]?
    
    /// 加入顶点。processor 为 nil 表示占位节点（如 Source/Sink）
    /// - Parameters:
    ///   - id: 节点 ID
    ///   - processor: 可选的滤镜实现
    func addNode(_ id: OFProcessNodeID, processor: OFProcessNode? = nil) {
        graph.addVertex(id)
        if let processor = processor {
            processors[id] = processor
        }
        cachedOrder = nil
    }
    
    /// 添加有向依赖：from 的输出作为 to 的输入
    /// - Parameters:
    ///   - from: 上游节点
    ///   - to: 下游节点
    func addEdge(from: OFProcessNodeID, to: OFProcessNodeID) {
        graph.addEdge(from: from, to: to)
        cachedOrder = nil
    }
    
    /// 按拓扑序处理一帧
    /// - Parameter frame: 采集封装后的视频帧，节点会原地改 pixelBuffer/texture
    func process(_ frame: VideoFrame) {
        // 构图未变则复用拓扑序
        if cachedOrder == nil {
            cachedOrder = graph.topologicalOrder()
        }
        guard let order = cachedOrder else {
            DDLogError("process graph has a cycle")
            return
        }
        // 无处理器或未开启的节点视为透传
        for id in order {
            guard let node = processors[id], node.isEnabled else {
                continue
            }
            node.process(frame)
        }
    }
}

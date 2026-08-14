//
//  SCGraph.swift
//  DataStructure
//
//  Created by anker on 2021/10/15.
//
//  有向图抽象：处理链路用顶点表示滤镜节点，用边表示数据流向。
//

import Foundation

/// 有向图协议。顶点类型需 Hashable，便于用字典存储。
public protocol SCGraph {
    /// 顶点上保存的业务数据类型
    associatedtype V where V: Hashable
    
    /// 当前图中有向边的数量
    /// - Returns: 边个数
    func edgesSize() -> Int
    
    /// 当前图中顶点的数量
    /// - Returns: 顶点个数
    func verticesSize() -> Int
    
    /// 添加一个顶点；若已存在则忽略
    /// - Parameter v: 顶点数据
    func addVertex(_ v: V)
    
    /// 添加一条无权重有向边；端点不存在时自动创建顶点
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    func addEdge(from: V, to: V)
    
    /// 添加一条带权重的有向边（处理图暂未使用权重）
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    ///   - weight: 可选权重
    func addEdge(from: V, to: V, weight: Double?)
    
    /// 删除顶点及其全部入边、出边
    /// - Parameter v: 要删除的顶点数据
    func removeVertex(_ v: V)
    
    /// 删除一条有向边；端点或边不存在时忽略
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    func removeEdge(from: V, to: V)
    
    /// 当前图中全部顶点值
    /// - Returns: 顶点数据数组（无序）
    func vertexValues() -> [V]
    
    /// 从 v 出发、沿出边可达的直接后继
    /// - Parameter v: 起点
    /// - Returns: 后继顶点数据；顶点不存在时返回空数组
    func outgoingNeighbors(of v: V) -> [V]
    
    /// 指向 v 的边数量，供拓扑排序使用
    /// - Parameter v: 目标顶点
    /// - Returns: 入度；顶点不存在时为 0
    func inDegree(of v: V) -> Int
    
    /// Kahn 算法求拓扑序；图中有环时返回 nil
    /// - Returns: 从入度为 0 开始的顶点序列，有环则为 nil
    func topologicalOrder() -> [V]?
}

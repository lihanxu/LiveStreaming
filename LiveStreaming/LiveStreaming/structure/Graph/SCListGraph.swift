//
//  SCListGraph.swift
//  DataStructure
//
//  Created by Hansen on 2021/10/18.
//
//  邻接表有向图：顶点字典 + 边集合。
//  直播处理链路用它描述「采集 → LUT → 滤镜 → 输出」的依赖，再拓扑排序后执行。
//

import Foundation

/// 邻接表实现的有向图。
public class SCListGraph<T> where T: Hashable {
    /// 顶点数据 -> 顶点对象
    private var vertices: Dictionary<T, SCGraphVertex<T>> = [:]
    /// 图中全部有向边
    private var edges: Set<SCGraphEdge<T>> = []
}

extension SCListGraph: CustomStringConvertible {
    /// 打印全部顶点的入边/出边以及边列表，便于调试构图
    public var description: String {
        var des: String = "[顶点]-------------------\n"
        for (v, vertex) in vertices {
            des.append("\(v)\n")
            des.append("out-----------\n")
            des.append("\(vertex.outEdges)\n")
            des.append("in-----------\n")
            des.append("\(vertex.inEdges)\n")
        }
        des.append("[边]-------------------\n")
        for edge in edges {
            des.append("\(edge)\n")
        }
        return des
    }
}

extension SCListGraph: SCGraph  {
    
    public typealias V = T
    
    /// - Returns: 边集合大小
    public func edgesSize() -> Int {
        return edges.count
    }
    
    /// - Returns: 顶点字典大小
    public func verticesSize() -> Int {
        return vertices.count
    }
    
    /// 添加顶点；已存在则直接返回
    /// - Parameter v: 顶点数据
    public func addVertex(_ v: T) {
        if vertices.contains(where: { $0.key == v }) {
            return
        }
        vertices[v] = SCGraphVertex(data: v)
    }
    
    /// 添加无权重有向边
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    public func addEdge(from: T, to: T) {
        addEdge(from: from, to: to, weight: nil)
    }
    
    /// 添加（或覆盖）一条有向边
    /// - Parameters:
    ///   - from: 起点数据
    ///   - to: 终点数据
    ///   - weight: 可选权重
    public func addEdge(from: T, to: T, weight: Double?) {
        // 1. 起点不存在则创建
        var fromVertex = vertices[from]
        if fromVertex == nil {
            fromVertex = SCGraphVertex(data: from)
            vertices[from] = fromVertex
        }
        // 2. 终点不存在则创建
        var toVertex = vertices[to]
        if toVertex == nil {
            toVertex = SCGraphVertex(data: to)
            vertices[to] = toVertex
        }
        let edge = SCGraphEdge(from: fromVertex!, to: toVertex!, weight: weight)
        // 3. 已有同向边则先从两端集合和全局边集删除，相当于更新
        if fromVertex!.outEdges.remove(edge) != nil {
            toVertex?.inEdges.remove(edge)
            edges.remove(edge)
        }
        // 4. 插入新边
        fromVertex?.outEdges.insert(edge)
        toVertex?.inEdges.insert(edge)
        edges.insert(edge)
    }
    
    /// 删除顶点，并清理所有与它相连的边
    /// - Parameter v: 顶点数据
    public func removeVertex(_ v: T) {
        guard let vertex = vertices.removeValue(forKey: v) else {
            return
        }
        // 出边：对端入边集合里也要删掉
        for edge in vertex.outEdges {
            edge.to.inEdges.remove(edge)
            edges.remove(edge)
        }
        // 入边：对端出边集合里也要删掉
        for edge in vertex.inEdges {
            edge.from.outEdges.remove(edge)
            edges.remove(edge)
        }
    }
    
    /// 删除 from -> to 的有向边
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    public func removeEdge(from: T, to: T) {
        guard let fromVertex = vertices[from] else {
            return
        }
        guard let toVertex = vertices[to] else {
            return
        }
        // 用同向边相等性匹配，不依赖权重
        let edge = SCGraphEdge(from: fromVertex, to: toVertex, weight: nil)
        if (fromVertex.outEdges.remove(edge) != nil) {
            toVertex.inEdges.remove(edge)
            edges.remove(edge)
        }
    }
    
    /// - Returns: 所有顶点 data
    public func vertexValues() -> [T] {
        return Array(vertices.keys)
    }
    
    /// 查询出边邻居
    /// - Parameter v: 起点
    /// - Returns: 后继 data 列表
    public func outgoingNeighbors(of v: T) -> [T] {
        guard let vertex = vertices[v] else {
            return []
        }
        return vertex.outEdges.map { $0.to.data }
    }
    
    /// 查询入度
    /// - Parameter v: 目标顶点
    /// - Returns: 入边条数
    public func inDegree(of v: T) -> Int {
        return vertices[v]?.inEdges.count ?? 0
    }
    
    /// Kahn 拓扑排序
    /// 1. 统计每个顶点当前入度，入度为 0 的入队
    /// 2. 出队一个顶点，把它的每个后继入度减 1，减到 0 再入队
    /// 3. 若弹出数量少于顶点数，说明有环
    /// - Returns: 拓扑序列；有环返回 nil
    public func topologicalOrder() -> [T]? {
        var remainingInDegree: [T: Int] = [:]
        let queue = SCQueue<T>()
        // 初始化入度表和零入度队列
        for value in vertices.keys {
            let degree = inDegree(of: value)
            remainingInDegree[value] = degree
            if degree == 0 {
                queue.enqueue(element: value)
            }
        }
        
        var order: [T] = []
        while let current = queue.dequeue() {
            order.append(current)
            // 释放 current 的后继依赖
            for neighbor in outgoingNeighbors(of: current) {
                guard let degree = remainingInDegree[neighbor] else {
                    continue
                }
                let nextDegree = degree - 1
                remainingInDegree[neighbor] = nextDegree
                if nextDegree == 0 {
                    queue.enqueue(element: neighbor)
                }
            }
        }
        
        if order.count != vertices.count {
            return nil
        }
        return order
    }
}

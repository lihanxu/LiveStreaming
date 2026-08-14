//
//  SCGraphEdge.swift
//  DataStructure
//
//  Created by anker on 2021/10/15.
//
//  有向边。相等性只比较 from/to，替换同向边时不依赖权重。
//

import Foundation

/// 有向边，可选权重。
public class SCGraphEdge<T> where T: Hashable {
    /// 边的起点顶点
    public var from: SCGraphVertex<T>
    /// 边的终点顶点
    public var to: SCGraphVertex<T>
    /// 边权；处理图当前不使用，预留给优先级等
    public let weight: Double?
    
    /// 构造一条有向边
    /// - Parameters:
    ///   - from: 起点
    ///   - to: 终点
    ///   - weight: 可选权重
    init(from: SCGraphVertex<T>, to: SCGraphVertex<T>, weight: Double?) {
        self.from = from
        self.to = to
        self.weight = weight
    }
}

extension SCGraphEdge: CustomStringConvertible {
    /// 调试描述：`A -> B` 或 `A -(w)-> B`
    public var description: String {
        guard let unwrappedWeight = weight else {
            return "\(from) -> \(to)"
        }
        return "\(from) -(\(unwrappedWeight))-> \(to)"
    }
}

extension SCGraphEdge: Hashable {
    /// 哈希组合起点、终点，有权重时再组合权重
    public func hash(into hasher: inout Hasher) {
        hasher.combine(from)
        hasher.combine(to)
        if weight != nil {
            hasher.combine(weight)
        }
    }

    /// 同向边视为同一条，便于 addEdge 时覆盖旧边（不比较权重）
    static public func == <T>(lhs:SCGraphEdge<T>, rhs: SCGraphEdge<T>) -> Bool {
        guard lhs.from == rhs.from else {
            return false
        }
        guard lhs.to == rhs.to else {
            return false
        }
        return true
    }
}

//
//  SCGraphVertex.swift
//  DataStructure
//
//  Created by Hansen on 2021/10/15.
//
//  邻接表图的顶点：用入边/出边集合描述与其它顶点的连接。
//

import Foundation

/// 图顶点。相等性和哈希只依赖 `data`，与边集合无关。
public class SCGraphVertex<T> where T: Hashable {
    /// 顶点携带的业务数据（处理图里是节点 ID）
    public var data: T
    /// 指向本顶点的边（入边）
    public var inEdges = Set<SCGraphEdge<T>>()
    /// 从本顶点出发的边（出边）
    public var outEdges = Set<SCGraphEdge<T>>()
    
    /// 用业务数据构造空连接的顶点
    /// - Parameter data: 顶点数据
    init(data: T) {
        self.data = data
    }
}

extension SCGraphVertex: CustomStringConvertible {
    /// 调试描述，只打印顶点数据
    public var description: String {
        return "vertex: \(data)"
    }
}

extension SCGraphVertex: Hashable {
    /// 哈希只组合 data，保证同一数据的顶点在 Set/Dictionary 中视为同一个
    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
    
    /// 两个顶点是否表示同一业务对象
    public static func == <T>(lhs: SCGraphVertex<T>, rhs: SCGraphVertex<T>) -> Bool {
        guard lhs.data == rhs.data else {
            return false
        }
        return true
    }
}

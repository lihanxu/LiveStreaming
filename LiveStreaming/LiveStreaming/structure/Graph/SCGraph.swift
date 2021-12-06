//
//  SCGraph.swift
//  DataStructure
//
//  Created by anker on 2021/10/15.
//

import Foundation

public protocol SCGraph {
    associatedtype V where V: Hashable
    /// 边数量
    func edgesSize() -> Int
    /// 顶点数量
    func verticesSize() -> Int
    /// 添加一个顶点
    func addVertex(_ v: V)
    /// 添加一条边
    func addEdge(from: V, to: V)
    /// 添加一条带权限的边
    func addEdge(from: V, to: V, weight: Double?)
    /// 删除一个顶点
    func removeVertex(_ v: V)
    /// 删除一条边
    func removeEdge(from: V, to: V)
}

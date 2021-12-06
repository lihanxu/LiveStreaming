//
//  SCListGraph.swift
//  DataStructure
//
//  Created by anker on 2021/10/18.
//

import Foundation

public class SCListGraph<T> where T: Hashable {
    private var vertices: Dictionary<T, SCGraphVertex<T>> = [:]
    private var edges: Set<SCGraphEdge<T>> = []
}

extension SCListGraph: CustomStringConvertible {
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
    
    public func edgesSize() -> Int {
        return edges.count
    }
    
    public func verticesSize() -> Int {
        return vertices.count
    }
    
    public func addVertex(_ v: T) {
        if vertices.contains(where: { $0.key == v }) {
            return
        }
        vertices[v] = SCGraphVertex(data: v)
    }
    
    public func addEdge(from: T, to: T) {
        addEdge(from: from, to: to, weight: nil)
    }
    
    public func addEdge(from: T, to: T, weight: Double?) {
        var fromVertex = vertices[from]
        if fromVertex == nil {
            fromVertex = SCGraphVertex(data: from)
            vertices[from] = fromVertex
        }
        var toVertex = vertices[to]
        if toVertex == nil {
            toVertex = SCGraphVertex(data: to)
            vertices[to] = toVertex
        }
        let edge = SCGraphEdge(from: fromVertex!, to: toVertex!, weight: weight)
        // 如果存在相同的边，删除原有的边
        if fromVertex!.outEdges.remove(edge) != nil {
            toVertex?.inEdges.remove(edge)
            edges.remove(edge)
        }
        fromVertex?.outEdges.insert(edge)
        toVertex?.inEdges.insert(edge)
        edges.insert(edge)
    }
    
    public func removeVertex(_ v: T) {
        guard let vertex = vertices.removeValue(forKey: v) else {
            return
        }
        // 删除出度相关的边，相关顶点也要删除以该边为入度的边
        for edge in vertex.outEdges {
            edge.to.inEdges.remove(edge)
            edges.remove(edge)
        }
        // 删除入度相关的边，相关顶点也要删除以该边为出度的边
        for edge in vertex.inEdges {
            edge.from.outEdges.remove(edge)
            edges.remove(edge)
        }
    }
    
    public func removeEdge(from: T, to: T) {
        guard let fromVertex = vertices[from] else {
            return
        }
        guard let toVertex = vertices[to] else {
            return
        }
        let edge = SCGraphEdge(from: fromVertex, to: toVertex, weight: nil)
        if (fromVertex.outEdges.remove(edge) != nil) {
            toVertex.inEdges.remove(edge)
            edges.remove(edge)
        }
    }
}

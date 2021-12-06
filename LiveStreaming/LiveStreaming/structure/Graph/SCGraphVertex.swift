//
//  SCGraphVertex.swift
//  DataStructure
//
//  Created by anker on 2021/10/15.
//

import Foundation

public class SCGraphVertex<T> where T: Hashable {
    public var data: T
    public var inEdges = Set<SCGraphEdge<T>>()
    public var outEdges = Set<SCGraphEdge<T>>()
    
    init(data: T) {
        self.data = data
    }
}

extension SCGraphVertex: CustomStringConvertible {
    public var description: String {
        return "vertex: \(data)"
    }
}

extension SCGraphVertex: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
    
    public static func == <T>(lhs: SCGraphVertex<T>, rhs: SCGraphVertex<T>) -> Bool {
        guard lhs.data == rhs.data else {
            return false
        }
        return true
    }
}

//
//  SCGraphEdge.swift
//  DataStructure
//
//  Created by anker on 2021/10/15.
//

import Foundation

public class SCGraphEdge<T> where T: Hashable {
    public var from: SCGraphVertex<T>
    public var to: SCGraphVertex<T>
    public let weight: Double?
    
    init(from: SCGraphVertex<T>, to: SCGraphVertex<T>, weight: Double?) {
        self.from = from
        self.to = to
        self.weight = weight
    }
}

extension SCGraphEdge: CustomStringConvertible {
    public var description: String {
        guard let unwrappedWeight = weight else {
            return "\(from) -> \(to)"
        }
        return "\(from) -(\(unwrappedWeight))-> \(to)"
    }
}

extension SCGraphEdge: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(from)
        hasher.combine(to)
        if weight != nil {
            hasher.combine(weight)
        }
    }

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

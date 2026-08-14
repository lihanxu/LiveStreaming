//
//  OFProcessGraph.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import Foundation
import CocoaLumberjack

class OFProcessGraph {
    private let graph = SCListGraph<OFProcessNodeID>()
    private var processors: [OFProcessNodeID: OFProcessNode] = [:]
    private var cachedOrder: [OFProcessNodeID]?
    
    func addNode(_ id: OFProcessNodeID, processor: OFProcessNode? = nil) {
        graph.addVertex(id)
        if let processor = processor {
            processors[id] = processor
        }
        cachedOrder = nil
    }
    
    func addEdge(from: OFProcessNodeID, to: OFProcessNodeID) {
        graph.addEdge(from: from, to: to)
        cachedOrder = nil
    }
    
    func process(_ frame: VideoFrame) {
        if cachedOrder == nil {
            cachedOrder = graph.topologicalOrder()
        }
        guard let order = cachedOrder else {
            DDLogError("process graph has a cycle")
            return
        }
        for id in order {
            guard let node = processors[id], node.isEnabled else {
                continue
            }
            node.process(frame)
        }
    }
}

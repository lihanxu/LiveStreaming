//
//  SCQueue.swift
//  DataStructure
//
//  Created by anker on 2021/6/27.
//

import Foundation
import CocoaLumberjack

/// FIFO 队列。图的 Kahn 拓扑排序用它存放入度为 0 的顶点。
class SCQueue<T> {
    /// 队列元素类型
    typealias Element = T
    /// 底层数组，队头为下标 0
    private var list = Array<T>()
    /// 可选互斥；拓扑排序单线程可不加
    private let semaphore: DispatchSemaphore?
    
    /// - Parameter withSemaphore: true 时 enqueue/dequeue 加锁
    init(withSemaphore: Bool = false) {
        semaphore = withSemaphore ? DispatchSemaphore(value: 1) : nil
    }

    /// 队列的元素个数
    func size() -> Int {
        return list.count
    }
    
    /// 队列是否为空
    func isEmpty() -> Bool {
        return list.isEmpty
    }
    
    /// 添加一个元素到队尾
    func enqueue(element: Element) {
        semaphore?.wait()
        DDLogVerbose("enqueue size:\(size())")
        list.append(element)
        semaphore?.signal()
    }
    
    /// 获取队头元素，并删除该元素
    func dequeue() -> Element? {
        semaphore?.wait()
        DDLogVerbose("dequeue size:\(size())")
        guard isEmpty() == false else {
            semaphore?.signal()
            return nil
        }
        let ele = list.remove(at: 0)
        semaphore?.signal()
        return ele
    }
    
    /// 获取队头元素，该元素不会被删除
    func peak() -> Element? {
        semaphore?.wait()
        DDLogVerbose("peak size:\(size())")
        guard isEmpty() == false else {
            semaphore?.signal()
            return nil
        }
        let ele = list[0]
        semaphore?.signal()
        return ele
    }
    
    /// 清除队列所有元素
    func clear() {
        semaphore?.wait()
        list.removeAll()
        semaphore?.signal()
    }
}

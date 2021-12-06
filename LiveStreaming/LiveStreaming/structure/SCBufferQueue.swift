//
//  SCBufferQueue.swift
//  DataStructure
//
//  Created by anker on 2021/11/10.
//

import Foundation

let defaultMaxSize: Int = 10

class SCBufferQueue<T> {
    typealias Element = T
    
    private var list = Array<T>()
    let contition: NSCondition!
    var maxSize: Int
    
    init(maxSize: Int = defaultMaxSize) {
        contition = NSCondition()
        self.maxSize = maxSize
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
        contition.lock()
        if list.count > maxSize {
            list.remove(at: 0)
        }
        list.append(element)
//        NSLog(#function, size())
        contition.signal()
        contition.unlock()
    }
    
    /// 获取队头元素，并删除该元素
    /// - parameter ms: 等待时长，单位是毫秒
    /// - returns: 返回队头元素，如果没有则返回空
    ///
    /// 获取队头元素，如果此时队列为空，则等待传入的时长，如果超时后队列依然为空，则返回nil
    func dequeue(wait ms: Int = 0) -> Element? {
        contition.lock()
        if ms > 0 {
            while list.isEmpty {
                contition.wait(until: Date(timeIntervalSinceNow: Double(ms)/1000.0))
            }
        }
        let ele = list.isEmpty ? nil : list.remove(at: 0)
//        NSLog(#function, size())
        contition.unlock()
        return ele
    }
    
    /// 获取队头元素，该元素不会被删除
    /// - parameter ms: 等待时长，单位是毫秒
    /// - returns: 返回队头元素，如果没有则返回空
    ///
    /// 获取队头元素，如果此时队列为空，则等待传入的时长，如果超时后队列依然为空，则返回nil
    func peak(wait ms: Int = 0) -> Element? {
        contition.lock()
        if ms > 0 {
            while list.isEmpty {
                contition.wait(until: Date(timeIntervalSinceNow: Double(ms)/1000.0))
            }
        }
        let ele = list.isEmpty ? nil : list[0]
//        NSLog(#function, size())
        contition.unlock()
        return ele
    }
    
    /// 清除队列所有元素
    func clear() {
        contition.lock()
        list.removeAll()
        contition.unlock()
    }
}
